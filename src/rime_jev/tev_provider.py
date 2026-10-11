"""Pinned, loopback-only Tev decisions; no downloads or cloud fallback."""

from __future__ import annotations

import json
import threading
import time
from collections.abc import Callable, Mapping
from typing import Any

import requests

from .providers import (
    IDLE_UNLOAD_SECONDS,
    Candidate,
    DecisionRequest,
    ProviderInputError,
    ProviderResult,
    _decision_instruction,
    _validate_probabilities,
)
from .tev_models import TEV_MODELS
from .tev_runtime import ensure_tev_server

DEFAULT_BASE_URL = "http://127.0.0.1:11435"
MAX_CANDIDATES = 23
MAX_REQUEST_BYTES = 64 * 1024
MAX_RESPONSE_BYTES = 128 * 1024
FULL_COMPLETION_CONTEXT_BYTES = 256
FULL_COMPLETION_CRITERIA_BYTES = 4096
STARTUP_TIMEOUT_SECONDS = 60.0
UNLOAD_TIMEOUT_SECONDS = 2.0
SHUTDOWN_TIMEOUT_SECONDS = STARTUP_TIMEOUT_SECONDS + UNLOAD_TIMEOUT_SECONDS + 3.0


class _TevFailure(Exception):
    def __init__(self, code: str) -> None:
        self.code = code


def _loopback_url(value: str) -> str:
    # Match the managed server without DNS, userinfo, or inherited host settings.
    if value != DEFAULT_BASE_URL:
        raise ValueError("Tev requires the fixed numeric loopback URL")
    return value


class TevProvider:
    """One selected tag, one operation at a time, with explicit asynchronous startup."""

    def __init__(
        self,
        provider_id: str,
        *,
        base_url: str = DEFAULT_BASE_URL,
        server_manager: Callable[[], str] | None = None,
        session: Any = None,
        idle_seconds: float = IDLE_UNLOAD_SECONDS,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        if provider_id not in TEV_MODELS:
            raise ValueError("Unsupported Tev provider")
        self._provider_id = provider_id
        self._model = dict(TEV_MODELS[provider_id])
        self._base_url = _loopback_url(base_url)
        self._manager = server_manager or ensure_tev_server
        self._session = session if session is not None else requests.Session()
        self._session.trust_env = False
        self._clock = clock
        self._idle_seconds = max(0.0, float(idle_seconds))
        self._lock = threading.RLock()
        self._state = "unavailable"
        self._error: str | None = "model_unavailable"
        self._closing = False
        self._owns_model = False
        self._last_activity = clock()
        self._load_thread: threading.Thread | None = None
        self._maintenance_stop = threading.Event()
        self._shutdown_attempt = threading.Event()
        self._shutdown_succeeded = False

    @property
    def provider_name(self) -> str:
        return self._provider_id

    @property
    def model_name(self) -> str:
        return self._model["tag"]

    @property
    def model(self) -> str:
        return self.model_name

    @property
    def status(self) -> str:
        with self._lock:
            return self._state

    def _result(self, status: str, *, started: float | None = None, **kwargs: Any) -> ProviderResult:
        return ProviderResult(
            status=status,
            provider=self.provider_name,
            model=self.model_name,
            elapsed_ms=0.0 if started is None else max(0.0, (self._clock() - started) * 1000),
            **kwargs,
        )

    def health(self) -> ProviderResult:
        with self._lock:
            if self._closing:
                return self._result("unavailable", error="runtime_closed")
            if self._state in {"unloaded", "unloading"}:
                return self._result("unavailable", error="unloaded")
            return self._result(self._state, error=self._error)

    def start(self) -> None:
        with self._lock:
            if self._closing or self._load_thread is not None:
                return
            self._state, self._error = "loading", None
            self._load_thread = threading.Thread(target=self._load_worker, name="rime-tev-load", daemon=True)
            self._load_thread.start()
            threading.Thread(target=self._maintenance_loop, name="rime-tev-idle", daemon=True).start()

    def wait_until_ready(self, timeout: float | None = None) -> bool:
        if self._load_thread is not None:
            self._load_thread.join(timeout)
        return self.health().status == "ready"

    def _load_worker(self) -> None:
        error = None
        deadline = self._clock() + STARTUP_TIMEOUT_SECONDS
        try:
            _loopback_url(self._manager())
            with self._lock:
                if self._closing:
                    return
            listing = self._request("GET", "/api/tags", deadline=deadline)
            models = listing.get("models") if isinstance(listing, Mapping) else None
            if not isinstance(models, list):
                raise _TevFailure("bad_response")
            matches = [row for row in models if isinstance(row, Mapping) and row.get("name") == self.model_name]
            if len(matches) != 1 or matches[0].get("digest") != self._model["digest"]:
                raise _TevFailure("model_unavailable")
            with self._lock:
                if self._closing:
                    return
                # Even a lost warmup response may have loaded this selected tag.
                self._owns_model = True
            warmup = DecisionRequest("warmup", "", "", (Candidate("ready", "runtime ready"),))
            response = self._request("POST", "/v1/systemone", self._build_request_body(warmup), deadline=deadline)
            self._validate_response(response, warmup)
        except _TevFailure as exc:
            error = exc.code
        except Exception:
            error = "model_load_failed"
        finally:
            with self._lock:
                closing = self._closing
                if not closing and error is None:
                    self._state, self._error = "ready", None
                    self._last_activity = self._clock()
                elif not closing:
                    self._state, self._error = "unavailable", error
            if closing:
                self._complete_shutdown()

    def _request(self, method: str, path: str, body: bytes | None = None, *, deadline: float) -> Any:
        remaining = deadline - self._clock()
        if remaining <= 0:
            raise _TevFailure("timeout")
        if body is not None and len(body) > MAX_REQUEST_BYTES:
            raise _TevFailure("invalid_request")
        response = None
        try:
            response = self._session.request(
                method,
                self._base_url + path,
                data=body,
                headers={"Content-Type": "application/json", "Accept": "application/json"},
                timeout=remaining,
                allow_redirects=False,
                stream=True,
            )
            if response.status_code != 200:
                raise _TevFailure("http_5xx" if response.status_code >= 500 else "http_4xx")
            length = response.headers.get("Content-Length")
            if length is not None and (int(length) < 0 or int(length) > MAX_RESPONSE_BYTES):
                raise _TevFailure("bad_response")
            content = bytearray()
            for chunk in response.iter_content(chunk_size=4096):
                if self._clock() >= deadline:
                    raise _TevFailure("timeout")
                if len(content) + len(chunk) > MAX_RESPONSE_BYTES:
                    raise _TevFailure("bad_response")
                content.extend(chunk)
            if self._clock() >= deadline:
                raise _TevFailure("timeout")
            return json.loads(content.decode("utf-8"))
        except _TevFailure:
            raise
        except (requests.Timeout, TimeoutError):
            raise _TevFailure("timeout") from None
        except (ValueError, UnicodeError):
            raise _TevFailure("bad_response") from None
        except Exception:
            raise _TevFailure("transport_error") from None
        finally:
            if response is not None:
                response.close()

    def _build_request_body(self, request: DecisionRequest) -> bytes:
        if len(request.candidates) > MAX_CANDIDATES:
            raise ProviderInputError
        criteria = {candidate.id: candidate.text for candidate in request.candidates}
        if request.context and len(request.context.encode("utf-8")) <= FULL_COMPLETION_CONTEXT_BYTES:
            completions = {candidate.id: request.context + candidate.text for candidate in request.candidates}
            if sum(len(text.encode("utf-8")) for text in completions.values()) <= FULL_COMPLETION_CRITERIA_BYTES:
                criteria = completions
        criteria["none"] = (
            "The current pinyin and declared candidates do not support a choice."
            if request.context == "" else
            "No declared candidate naturally continues the preceding context."
        )
        body = json.dumps(
            {
                "model": self.model_name,
                "state": {"context": request.context, "pinyin": request.pinyin},
                "questions": {"candidate": {
                    "type": "choice", "instructions": _decision_instruction(request), "criteria": criteria,
                }},
                "keep_alive": "10m",
            },
            ensure_ascii=False, separators=(",", ":"), allow_nan=False,
        ).encode("utf-8")
        if len(body) > MAX_REQUEST_BYTES:
            raise ProviderInputError
        return body

    def _validate_response(self, payload: Any, request: DecisionRequest) -> tuple[str, dict[str, float]]:
        try:
            if not isinstance(payload, Mapping) or payload.get("model") != self.model_name:
                raise ValueError
            answer = payload["answers"]["candidate"]
            labels = tuple(candidate.id for candidate in request.candidates) + ("none",)
            if answer["type"] != "choice" or answer["choice"] not in labels:
                raise ValueError
            probabilities, _ = _validate_probabilities(labels, answer["probabilities"])
            choice = answer["choice"]
            if probabilities[choice] < max(probabilities.values()):
                raise ValueError
            return choice, probabilities
        except (ValueError, TypeError, KeyError, IndexError):
            raise _TevFailure("bad_response") from None

    def decide(self, request: DecisionRequest) -> ProviderResult:
        started = self._clock()
        try:
            # Direct callers get the same validation as Unix-socket callers.
            DecisionRequest.from_payload({
                "state": {"context": request.context, "pinyin": request.pinyin, "abbreviated": request.abbreviated},
                "candidates": [{"id": c.id, "text": c.text} for c in request.candidates],
                "max_age_ms": request.max_age_ms,
            })
            body = self._build_request_body(request)
        except (ProviderInputError, ValueError, TypeError, AttributeError):
            return self._result("error", started=started, error="invalid_request")
        deadline = started + request.max_age_ms / 1000
        with self._lock:
            if self._closing or self._state != "ready":
                return self.health()
            if not request.candidates:
                return self._result("no_match", started=started)
            if self._clock() >= deadline:
                return self._result("error", started=started, error="timeout")
            self._state = "busy"
        done = threading.Event()
        holder: list[ProviderResult] = []

        def run() -> None:
            try:
                response = self._request("POST", "/v1/systemone", body, deadline=deadline)
                choice, probabilities = self._validate_response(response, request)
                holder.append(self._result(
                    "no_match" if choice == "none" else "ready", started=started,
                    choice_id=None if choice == "none" else choice, probabilities=probabilities,
                ))
            except _TevFailure as exc:
                holder.append(self._result("error", started=started, error=exc.code))
            except Exception:
                holder.append(self._result("error", started=started, error="inference_failed"))
            finally:
                with self._lock:
                    closing = self._closing
                    if not closing:
                        self._state = "ready"
                        self._last_activity = self._clock()
                if closing:
                    self._complete_shutdown()
                done.set()

        threading.Thread(target=run, name="rime-tev-inference", daemon=True).start()
        if not done.wait(max(0.0, deadline - self._clock())) or self._clock() >= deadline:
            return self._result("error", started=started, error="timeout")
        with self._lock:
            if self._closing:
                return self.health()
        return holder[0]

    def _release_model(self) -> bool:
        with self._lock:
            if not self._owns_model:
                return True
        try:
            body = json.dumps({"model": self.model_name, "keep_alive": 0, "stream": False}).encode("utf-8")
            response = self._request("POST", "/api/generate", body, deadline=self._clock() + UNLOAD_TIMEOUT_SECONDS)
            if not isinstance(response, Mapping) or response.get("model") != self.model_name or response.get("done") is not True:
                raise _TevFailure("bad_response")
            with self._lock:
                self._owns_model = False
            return True
        except Exception:
            return False

    def unload_if_idle(self, now: float | None = None) -> bool:
        now = self._clock() if now is None else now
        with self._lock:
            if self._closing or self._state != "ready" or now - self._last_activity < self._idle_seconds:
                return False
            self._state = "unloading"
        released = self._release_model()
        with self._lock:
            self._state, self._error = ("unloaded", "unloaded") if released else ("unavailable", "model_unavailable")
            closing = self._closing
        if closing:
            self._complete_shutdown(released=released)
        return released

    def _maintenance_loop(self) -> None:
        while not self._maintenance_stop.wait(1.0):
            self.unload_if_idle()

    def _complete_shutdown(self, *, released: bool | None = None) -> None:
        succeeded = False
        try:
            if released is None:
                released = self._release_model()
            if released:
                self._session.close()
                succeeded = True
        except Exception:
            pass
        finally:
            with self._lock:
                self._shutdown_succeeded = succeeded
                self._shutdown_attempt.set()

    def shutdown(self, *, timeout: float = SHUTDOWN_TIMEOUT_SECONDS) -> bool:
        """Wait for release; an explicit call after failure retries only the selected unload."""
        with self._lock:
            first = not self._closing
            retry = self._shutdown_attempt.is_set() and not self._shutdown_succeeded
            if first:
                self._closing = True
                self._maintenance_stop.set()
                active = self._state in {"loading", "busy", "unloading"}
                self._state, self._error = "unavailable", "runtime_closed"
            if retry:
                # Keep concurrent waiters attached to the attempt they observed.
                self._shutdown_attempt = threading.Event()
            attempt = self._shutdown_attempt
            if (first and not active) or retry:
                threading.Thread(target=self._complete_shutdown, name="rime-tev-shutdown", daemon=True).start()
        return attempt.wait(timeout=max(0.0, timeout)) and self._shutdown_succeeded
