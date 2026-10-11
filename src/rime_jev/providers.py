"""Decision providers for the bounded Rime-Jev runtime.

The input method owns candidate generation.  Providers only choose one of the
declared candidates (or ``none``); they never generate text.  The module keeps
the two providers behind the same small, synchronous-in-the-caller API.  The
runtime calls that API from a per-connection worker, while each provider
protects its model/network operation with a single-task gate.
"""

from __future__ import annotations

import gc
import json
import math
import os
import socket
import ssl
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import deque
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from datetime import datetime, timezone
from zoneinfo import ZoneInfo
from email.utils import parsedate_to_datetime
from pathlib import Path
from typing import Any

from .http_transport import HTTPTransportError, JevHTTPTransport

try:  # The runtime can still expose Jev health when the optional local SDK is absent.
    from thisthat import Question, TypedDecider
except Exception:  # pragma: no cover - exercised only in environments without thisthat.
    Question = None  # type: ignore[assignment,misc]
    TypedDecider = None  # type: ignore[assignment,misc]


MAX_OPTIONS = 255
MAX_STATE_TOKENS = 1024
DEFAULT_MAX_AGE_MS = 1500
MAX_MAX_AGE_MS = 10 * 60 * 1000
IDLE_UNLOAD_SECONDS = 600.0
LOCAL_MODEL_ID = "flock-io/this-that-model-1.2"
JEV_MODEL_ID = "jev-1.13.0"
JEV_ENDPOINT = "https://api.typesafe.ai/v1/systemone"
DECISION_INSTRUCTION = (
    "Given the immediately preceding state.context, which declared candidate is the most "
    "natural match for the user's intent in the current pinyin? Choose none only when every "
    "declared candidate is inapplicable; uncertainty about the user's intent alone is not a "
    "reason to choose none."
)
ABBREVIATED_INSTRUCTION = (
    "这是中文输入法的简拼候选排序。所有候选词均已通过 Rime 的拼音匹配，"
    "无须检查简拼字母是否等于完整拼音。请比较各候选词接在前文之后的完整表达，"
    "选择语法最通顺、语义最连贯、最符合日常表达习惯的一项。"
    "只有所有候选词都无法自然接续前文时才选择 none。"
)
JEV_RATE_LIMIT_PER_SECOND = 4
JEV_COOLDOWN_SECONDS = 30.0
JEV_MAX_RETRY_AFTER_SECONDS = 60.0
JEV_DEFAULT_RETRY_AFTER_SECONDS = 1.0
DEFAULT_DAILY_BUDGET_USD = 0.25
# TypeSafe published input pricing is $0.042 per million tokens. Keep this
# as a per-token value so tests and deployments can inject the current tariff.
DEFAULT_INPUT_TOKEN_PRICE_USD = 0.000000042
DEFAULT_OUTPUT_TOKEN_PRICE_USD = 0.0
DEFAULT_BUDGET_PATH = os.path.expanduser("~/Library/Application Support/Rime-Jev/jev-budget.json")
MAX_REQUEST_BODY_BYTES = 512 * 1024
# Public defaults cannot reach a credential service. Configure only metadata;
# the helper returns a short-lived bearer through captured stdout at runtime.
VAULT_URL = os.environ.get("RIME_JEV_VAULT_URL", "https://vault.example.invalid")
DEFAULT_VAULT_TOKEN_HELPER = os.environ.get("RIME_JEV_VAULT_TOKEN_HELPER", "")

WARMUP_STATE = "rime-jev local decision runtime warmup"
WARMUP_QUESTION = "Is this fixed local runtime warmup request ready?"
WARMUP_OPTIONS = ("ready", "not_ready")

ERROR_CODES = frozenset(
    {
        "invalid_request",
        "model_unavailable",
        "model_load_failed",
        "inference_failed",
        "timeout",
        "bad_response",
        "credential_unavailable",
        "http_401",
        "http_4xx",
        "http_429",
        "http_5xx",
        "transport_error",
        "rate_limited",
        "cooldown",
        "budget_exhausted",
        "budget_unavailable",
        "runtime_closed",
        "unloaded",
        "message_too_large",
        "invalid_json",
        "unsupported_operation",
        "read_timeout",
    }
)


class ProviderInputError(ValueError):
    """A request failed the fixed, non-payload-bearing input contract."""

    code = "invalid_request"


class CredentialUnavailable(RuntimeError):
    """The configured Vault ref could not produce an API secret."""

    code = "credential_unavailable"


@dataclass(frozen=True)
class Candidate:
    """One candidate supplied by Rime."""

    id: str
    text: str


@dataclass(frozen=True)
class DecisionRequest:
    """Validated request passed to either provider."""

    request_id: Any
    context: str
    pinyin: str
    candidates: tuple[Candidate, ...]
    max_age_ms: int = DEFAULT_MAX_AGE_MS
    abbreviated: bool = False

    @property
    def id(self) -> Any:
        """The wire-level request id, exposed for evaluation callers."""

        return self.request_id

    @classmethod
    def from_payload(cls, payload: Mapping[str, Any]) -> "DecisionRequest":
        if not isinstance(payload, Mapping):
            raise ProviderInputError

        state = payload.get("state")
        if not isinstance(state, Mapping):
            raise ProviderInputError
        context = state.get("context")
        pinyin = state.get("pinyin")
        if not isinstance(context, str) or not isinstance(pinyin, str):
            raise ProviderInputError

        abbreviated = state.get("abbreviated", False)
        if not isinstance(abbreviated, bool):
            raise ProviderInputError

        raw_candidates = payload.get("candidates")
        if not isinstance(raw_candidates, list):
            raise ProviderInputError
        if len(raw_candidates) + 1 > MAX_OPTIONS:
            raise ProviderInputError
        candidates: list[Candidate] = []
        seen_ids: set[str] = set()
        for raw in raw_candidates:
            if not isinstance(raw, Mapping):
                raise ProviderInputError
            candidate_id = raw.get("id")
            text = raw.get("text")
            if (
                not isinstance(candidate_id, str)
                or not candidate_id
                or candidate_id == "none"
                or not isinstance(text, str)
            ):
                raise ProviderInputError
            if candidate_id in seen_ids:
                raise ProviderInputError
            seen_ids.add(candidate_id)
            candidates.append(Candidate(candidate_id, text))

        raw_age = payload.get("max_age_ms", DEFAULT_MAX_AGE_MS)
        if isinstance(raw_age, bool) or not isinstance(raw_age, (int, float)):
            raise ProviderInputError
        if not math.isfinite(float(raw_age)):
            raise ProviderInputError
        if raw_age < 0 or raw_age > MAX_MAX_AGE_MS:
            raise ProviderInputError

        return cls(
            request_id=payload.get("id"),
            context=context,
            pinyin=pinyin,
            candidates=tuple(candidates),
            max_age_ms=int(raw_age),
            abbreviated=abbreviated,
        )


@dataclass(frozen=True)
class ProviderResult:
    """Provider result before the runtime adds its request id."""

    status: str
    provider: str
    model: str
    choice_id: str | None = None
    probabilities: Mapping[str, float] | None = None
    elapsed_ms: float = 0.0
    usage: Mapping[str, int] | None = None
    error: str | None = None

    def to_dict(self, request_id: Any) -> dict[str, Any]:
        probabilities = dict(self.probabilities or {"none": 1.0})
        out: dict[str, Any] = {
            "id": request_id,
            "status": self.status,
            "provider": self.provider,
            "model": self.model,
            "choice_id": self.choice_id,
            "probabilities": probabilities,
            "elapsed_ms": round(max(0.0, float(self.elapsed_ms)), 2),
        }
        if self.usage:
            out["usage"] = dict(self.usage)
        if self.error:
            # Error values are deliberately a closed set.  Never serialize exception text.
            out["error"] = self.error if self.error in ERROR_CODES else "inference_failed"
        return out

    def to_wire(self, request_id: Any) -> dict[str, Any]:
        """Explicit alias used by small offline evaluation scripts."""

        return self.to_dict(request_id)


def _now_ms(start: float) -> float:
    return (time.monotonic() - start) * 1000.0


def _safe_error(code: str) -> str:
    return code if code in ERROR_CODES else "inference_failed"


def _empty_probabilities() -> dict[str, float]:
    return {"none": 1.0}


def _result(
    *,
    status: str,
    provider: str,
    model: str,
    started: float,
    choice_id: str | None = None,
    probabilities: Mapping[str, float] | None = None,
    usage: Mapping[str, int] | None = None,
    error: str | None = None,
) -> ProviderResult:
    return ProviderResult(
        status=status,
        provider=provider,
        model=model,
        choice_id=choice_id,
        probabilities=dict(probabilities or _empty_probabilities()),
        elapsed_ms=_now_ms(started),
        usage=dict(usage) if usage else None,
        error=_safe_error(error) if error else None,
    )


def _validate_probabilities(
    labels: Sequence[str], raw: Any
) -> tuple[dict[str, float], str | None]:
    if not isinstance(raw, Mapping):
        raise ValueError("bad probabilities")
    if set(raw) != set(labels):
        raise ValueError("bad probability labels")
    values: list[float] = []
    for label in labels:
        value = raw.get(label)
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ValueError("bad probability value")
        value = float(value)
        if not math.isfinite(value) or value < 0.0 or value > 1.0:
            raise ValueError("bad probability value")
        values.append(value)
    total = sum(values)
    if not math.isfinite(total) or abs(total - 1.0) > 1e-3:
        raise ValueError("bad probability total")
    if total <= 0.0:
        raise ValueError("empty probability total")
    return {label: value / total for label, value in zip(labels, values)}, None


def _mapped_probabilities(
    request: DecisionRequest,
    labels: Sequence[str],
    probabilities: Mapping[str, float],
) -> dict[str, float]:
    mapped: dict[str, float] = {}
    for index, candidate in enumerate(request.candidates):
        mapped[candidate.id] = float(probabilities[labels[index]])
    mapped["none"] = float(probabilities["none"])
    return mapped


def _candidate_options(request: DecisionRequest) -> tuple[str, ...]:
    """Build distinct, readable local labels while retaining id/text in every option."""

    # JSON encoding prevents delimiter collisions and makes id/text identity explicit.
    options = tuple(
        "candidate " + json.dumps({"id": candidate.id, "text": candidate.text}, ensure_ascii=False)
        for candidate in request.candidates
    )
    return options + ("none " + json.dumps({"id": "none", "text": "no candidate matches"}),)


def _decision_instruction(request: DecisionRequest) -> str:
    return ABBREVIATED_INSTRUCTION if request.abbreviated else DECISION_INSTRUCTION


def _build_local_question(request: DecisionRequest) -> Any:
    if Question is None:
        raise RuntimeError("thisthat unavailable")
    options = _candidate_options(request)
    if len(options) > MAX_OPTIONS:
        raise ProviderInputError
    return Question(_decision_instruction(request), options)


def _tokenize(tokenizer: Any, text: str) -> list[int]:
    encoded = tokenizer.encode(text, add_special_tokens=False)
    if isinstance(encoded, Mapping):
        encoded = encoded.get("input_ids")
    if not isinstance(encoded, Sequence):
        raise ValueError("tokenizer returned an invalid sequence")
    return [int(token) for token in encoded]


def _decode(tokenizer: Any, tokens: Sequence[int]) -> str:
    try:
        return str(tokenizer.decode(list(tokens), skip_special_tokens=True))
    except TypeError:
        return str(tokenizer.decode(list(tokens)))


def trim_state_to_token_limit(
    tokenizer: Any, context: str, pinyin: str, *, max_tokens: int = MAX_STATE_TOKENS
) -> str:
    """Keep the newest context tokens and the complete current pinyin when possible.

    This is intentionally done by the provider worker, away from the input/connection thread.
    The official SDK receives the already bounded state as well as the explicit bound, so it
    cannot silently drop the current pinyin through its own prompt truncation.
    """

    if max_tokens <= 0:
        return pinyin[-1:]
    context_text = context
    suffix_text = "\npinyin: " + pinyin
    context_tokens = _tokenize(tokenizer, context_text)
    suffix_tokens = _tokenize(tokenizer, suffix_text)

    if len(suffix_tokens) >= max_tokens:
        return _decode(tokenizer, suffix_tokens[-max_tokens:])
    keep_context = max_tokens - len(suffix_tokens)
    while keep_context >= 0:
        selected = context_tokens[-keep_context:] + suffix_tokens if keep_context else suffix_tokens
        state = _decode(tokenizer, selected)
        try:
            if len(_tokenize(tokenizer, state)) <= max_tokens:
                return state
        except Exception:
            # If a tokenizer cannot re-encode decoded text, the selected token sequence is still
            # bounded and the official SDK receives the explicit max_state_tokens below.
            return state
        keep_context -= 1
    return _decode(tokenizer, suffix_tokens[-max_tokens:])


def _close_model(decider: Any) -> None:
    if decider is None:
        return
    for target in (decider, getattr(decider, "backend", None), getattr(decider, "model", None)):
        close = getattr(target, "close", None)
        if callable(close):
            try:
                close()
            except Exception:
                pass
    gc.collect()


def _load_local_decider(model_path: str | os.PathLike[str]) -> Any:
    if TypedDecider is None:
        raise RuntimeError("thisthat unavailable")
    path = Path(model_path)
    if not path.exists():
        raise FileNotFoundError
    os.environ["HF_HUB_OFFLINE"] = "1"
    return TypedDecider.from_pretrained(str(path), device="auto")


class LocalProvider:
    """Offline this-that-model provider with bounded loading and inference concurrency."""

    provider_name = "local"
    model_name = LOCAL_MODEL_ID

    def __init__(
        self,
        model_path: str | os.PathLike[str],
        *,
        loader: Callable[[str | os.PathLike[str]], Any] | None = None,
        warmup: bool = True,
        idle_seconds: float = IDLE_UNLOAD_SECONDS,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.model_path = str(model_path)
        self._loader = loader or _load_local_decider
        self._warmup = warmup
        self._idle_seconds = max(0.0, float(idle_seconds))
        self._clock = clock
        # Set this synchronously so no load path can briefly consult the Hub before the loader
        # thread gets scheduled.
        os.environ["HF_HUB_OFFLINE"] = "1"
        self._lock = threading.RLock()
        self._decider: Any = None
        self._state = "unloaded"
        self._error: str | None = None
        self._busy = False
        self._closing = False
        self._last_activity = self._clock()
        self._load_thread: threading.Thread | None = None
        self._maintenance_stop = threading.Event()
        self._maintenance_thread: threading.Thread | None = None

    @property
    def status(self) -> str:
        return self.health().status

    @property
    def model(self) -> str:
        return self.model_name

    def start(self) -> None:
        """Start the maintenance loop and asynchronous model load."""

        with self._lock:
            if self._closing:
                return
            if self._maintenance_thread is None:
                self._maintenance_thread = threading.Thread(
                    target=self._maintenance_loop,
                    name="rime-jev-local-maintenance",
                    daemon=True,
                )
                self._maintenance_thread.start()
            self._start_loading_locked()

    def start_loading(self) -> bool:
        """Begin a load if the model is unloaded; return whether a thread was started."""

        with self._lock:
            return self._start_loading_locked()

    def _start_loading_locked(self) -> bool:
        if self._closing or self._state == "loading" or self._state == "ready":
            return False
        if self._state == "busy":
            return False
        self._error = None
        self._state = "loading"
        self._load_thread = threading.Thread(
            target=self._load_worker,
            name="rime-jev-local-loader",
            daemon=True,
        )
        self._load_thread.start()
        return True

    def _load_worker(self) -> None:
        decider = None
        try:
            os.environ["HF_HUB_OFFLINE"] = "1"
            decider = self._loader(self.model_path)
            if self._warmup:
                if Question is None:
                    raise RuntimeError("thisthat unavailable")
                warmup_question = Question(WARMUP_QUESTION, WARMUP_OPTIONS)
                # The warmup is fixed and contains no request or user text.
                decider.decide(
                    WARMUP_STATE,
                    warmup_question,
                    max_state_tokens=MAX_STATE_TOKENS,
                )
        except Exception:
            _close_model(decider)
            with self._lock:
                self._decider = None
                self._state = "unavailable"
                self._error = "runtime_closed" if self._closing else "model_load_failed"
            return

        with self._lock:
            if self._closing:
                _close_model(decider)
                return
            self._decider = decider
            self._last_activity = self._clock()
            self._state = "ready"
            self._error = None

    def wait_until_ready(self, timeout: float | None = None) -> bool:
        """Convenience hook for offline evaluation scripts; it never starts a load implicitly."""

        thread = self._load_thread
        if thread is not None:
            thread.join(timeout=timeout)
        return self.health().status == "ready"

    def health(self) -> ProviderResult:
        started = self._clock()
        with self._lock:
            if self._closing:
                status, error = "unavailable", "runtime_closed"
            elif self._busy:
                status, error = "busy", None
            elif self._state == "loading":
                status, error = "loading", None
            elif self._state == "ready":
                status, error = "ready", None
            elif self._state == "unavailable":
                status, error = "unavailable", self._error or "model_unavailable"
            else:
                status, error = "unavailable", "unloaded"
        return _result(
            status=status,
            provider=self.provider_name,
            model=self.model_name,
            started=started,
            error=error,
        )

    def decide(self, request: DecisionRequest) -> ProviderResult:
        started = self._clock()
        if not request.candidates:
            return _result(
                status="no_match",
                provider=self.provider_name,
                model=self.model_name,
                started=started,
            )
        if len(request.candidates) + 1 > MAX_OPTIONS:
            return _result(
                status="error",
                provider=self.provider_name,
                model=self.model_name,
                started=started,
                error="invalid_request",
            )

        with self._lock:
            if self._closing:
                return _result(
                    status="unavailable",
                    provider=self.provider_name,
                    model=self.model_name,
                    started=started,
                    error="runtime_closed",
                )
            if self._state == "loading":
                return _result(
                    status="loading",
                    provider=self.provider_name,
                    model=self.model_name,
                    started=started,
                )
            if self._busy:
                return _result(
                    status="busy",
                    provider=self.provider_name,
                    model=self.model_name,
                    started=started,
                )
            if self._state != "ready" or self._decider is None:
                if self._state == "unloaded":
                    self._start_loading_locked()
                    return _result(
                        status="loading",
                        provider=self.provider_name,
                        model=self.model_name,
                        started=started,
                    )
                return _result(
                    status="unavailable",
                    provider=self.provider_name,
                    model=self.model_name,
                    started=started,
                    error=self._error or "model_unavailable",
                )
            self._busy = True
            decider = self._decider

        done = threading.Event()
        holder: dict[str, Any] = {}

        def run() -> None:
            try:
                holder["result"] = self._run_decision(decider, request, started)
            except ValueError:
                holder["error"] = "bad_response"
            except Exception:
                holder["error"] = "inference_failed"
            finally:
                with self._lock:
                    self._busy = False
                    self._last_activity = self._clock()
                    closing = self._closing
                if closing:
                    _close_model(decider)
                done.set()

        threading.Thread(target=run, name="rime-jev-local-inference", daemon=True).start()
        if not done.wait(timeout=max(0.0, request.max_age_ms / 1000.0)):
            return _result(
                status="error",
                provider=self.provider_name,
                model=self.model_name,
                started=started,
                error="timeout",
            )
        if "error" in holder:
            return _result(
                status="error",
                provider=self.provider_name,
                model=self.model_name,
                started=started,
                error=str(holder["error"]),
            )
        return holder["result"]

    def _run_decision(
        self, decider: Any, request: DecisionRequest, started: float
    ) -> ProviderResult:
        tokenizer = getattr(decider, "tokenizer", None)
        if tokenizer is None:
            raise RuntimeError("missing tokenizer")
        state = trim_state_to_token_limit(tokenizer, request.context, request.pinyin)
        question = _build_local_question(request)
        decision = decider.decide(
            state,
            question,
            max_state_tokens=MAX_STATE_TOKENS,
        )
        options = tuple(question.options)
        index = getattr(decision, "index", None)
        raw_options = tuple(getattr(decision, "options", ()))
        raw_probabilities = tuple(getattr(decision, "probabilities", ()))
        if not isinstance(index, int) or isinstance(index, bool):
            raise ValueError("bad decision index")
        if raw_options != options or not 0 <= index < len(options):
            raise ValueError("bad decision options")
        if len(raw_probabilities) != len(options):
            raise ValueError("bad decision probabilities")
        labels, probabilities = _validate_local_probabilities(options, raw_probabilities)
        mapped = {
            candidate.id: float(probabilities[labels[position]])
            for position, candidate in enumerate(request.candidates)
        }
        mapped["none"] = float(probabilities[labels[-1]])
        if index == len(labels) - 1:
            return _result(
                status="no_match",
                provider=self.provider_name,
                model=self.model_name,
                started=started,
                probabilities=mapped,
            )
        return _result(
            status="ready",
            provider=self.provider_name,
            model=self.model_name,
            started=started,
            choice_id=request.candidates[index].id,
            probabilities=mapped,
        )

    def unload(self) -> bool:
        """Release model references immediately; the next decision starts a fresh async load."""

        with self._lock:
            if self._busy or self._state == "loading":
                return False
            decider = self._decider
            self._decider = None
            self._state = "unloaded"
            self._error = "unloaded"
        _close_model(decider)
        return decider is not None

    def unload_if_idle(self, now: float | None = None) -> bool:
        now = self._clock() if now is None else now
        with self._lock:
            idle = now - self._last_activity
            if (
                self._state != "ready"
                or self._busy
                or self._decider is None
                or idle < self._idle_seconds
            ):
                return False
        return self.unload()

    def _maintenance_loop(self) -> None:
        while not self._maintenance_stop.wait(1.0):
            try:
                self.unload_if_idle()
            except Exception:
                # Maintenance must never kill the process or affect health responsiveness.
                pass

    def shutdown(self) -> None:
        with self._lock:
            if self._closing:
                return
            self._closing = True
            self._maintenance_stop.set()
            decider = self._decider
            self._decider = None
            busy = self._busy
            self._state = "unavailable"
            self._error = "runtime_closed"
        if not busy:
            _close_model(decider)


def _validate_local_probabilities(
    labels: Sequence[str], raw: Sequence[Any]
) -> tuple[tuple[str, ...], dict[str, float]]:
    if len(raw) != len(labels):
        raise ValueError("bad probability length")
    values: list[float] = []
    for value in raw:
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ValueError("bad probability value")
        value = float(value)
        if not math.isfinite(value) or value < 0.0 or value > 1.0:
            raise ValueError("bad probability value")
        values.append(value)
    total = sum(values)
    if total <= 0.0 or not math.isfinite(total) or abs(total - 1.0) > 1e-3:
        raise ValueError("bad probability total")
    return tuple(labels), {label: value / total for label, value in zip(labels, values)}


def _system_ssl_context() -> ssl.SSLContext:
    """Return system-verified TLS, optionally using truststore when installed."""

    try:
        import truststore  # type: ignore

        return truststore.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    except ImportError:
        return ssl.create_default_context()


class _RejectRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Reject redirects before urllib can resend an Authorization header."""

    def redirect_request(
        self,
        req: urllib.request.Request,
        fp: Any,
        code: int,
        msg: str,
        headers: Any,
        newurl: str,
    ) -> urllib.request.Request:
        raise urllib.error.HTTPError(req.full_url, code, "redirect disabled", headers, fp)


class VaultSecretReader:
    """Read one already-confirmed scalar ref through a configured Vault-compatible helper.

    The ref is metadata supplied by the caller.  This class never lists or searches the Vault
    catalog, never writes a secret to disk, and never includes the token or value in an exception
    or log.  Tests inject ``urlopen`` and ``run``; production uses the configured helper and verified HTTPS.
    """

    def __init__(
        self,
        *,
        vault_url: str = VAULT_URL,
        helper_path: str | os.PathLike[str] = DEFAULT_VAULT_TOKEN_HELPER,
        urlopen: Callable[..., Any] | None = None,
        run: Callable[..., Any] | None = None,
        ssl_context: ssl.SSLContext | None = None,
    ) -> None:
        self.vault_url = vault_url.rstrip("/")
        self.helper_path = str(helper_path)
        self._urlopen = urlopen
        self._run = run or subprocess.run
        self._ssl_context = ssl_context or _system_ssl_context()
        parsed = urllib.parse.urlsplit(self.vault_url)
        if parsed.scheme != "https" or not parsed.hostname:
            raise ValueError("Vault URL must use HTTPS")
        self._vault_origin = (parsed.scheme, parsed.hostname.lower(), parsed.port or 443)
        self._opener = (
            urllib.request.build_opener(
                _RejectRedirectHandler(),
                urllib.request.HTTPSHandler(context=self._ssl_context),
            )
            if urlopen is None
            else None
        )

    def __call__(self, ref: str) -> str:
        return self.read(ref)

    def read(self, ref: str) -> str:
        if not isinstance(ref, str) or not ref or "/" in ref or ".." in ref:
            raise CredentialUnavailable
        token = ""
        try:
            try:
                completed = self._run(
                    [self.helper_path],
                    check=True,
                    capture_output=True,
                    text=True,
                    timeout=15,
                )
                token = str(getattr(completed, "stdout", "") or "").strip()
            except Exception as exc:
                raise CredentialUnavailable from exc
            if not token:
                raise CredentialUnavailable

            url = f"{self.vault_url}/api/v1/secrets/{urllib.parse.quote(ref, safe='')}"
            parsed_url = urllib.parse.urlsplit(url)
            if (
                parsed_url.scheme,
                (parsed_url.hostname or "").lower(),
                parsed_url.port or 443,
            ) != self._vault_origin:
                raise CredentialUnavailable
            request = urllib.request.Request(
                url,
                headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
                method="GET",
            )
            try:
                if self._urlopen is not None:
                    # Preserve the existing injection contract exactly.
                    response = self._urlopen(request, timeout=10, context=self._ssl_context)
                else:
                    opener = self._opener
                    if opener is None:
                        raise CredentialUnavailable
                    response = opener.open(request, timeout=10)
                raw = _read_response(response, 64 * 1024)
            except Exception as exc:
                raise CredentialUnavailable from exc
            try:
                payload = json.loads(raw.decode("utf-8"))
            except Exception as exc:
                raise CredentialUnavailable from exc
            if not isinstance(payload, Mapping) or payload.get("ref") != ref:
                raise CredentialUnavailable
            value = payload.get("value")
            if not isinstance(value, str) or not value:
                raise CredentialUnavailable
            return value
        finally:
            # Do not retain the service bearer beyond the one read.
            token = ""


def _read_response(response: Any, limit: int) -> bytes:
    try:
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = response.read(min(8192, limit - total + 1))
            if not chunk:
                break
            if not isinstance(chunk, bytes):
                chunk = bytes(chunk)
            total += len(chunk)
            if total > limit:
                raise ValueError("response too large")
            chunks.append(chunk)
        return b"".join(chunks)
    finally:
        close = getattr(response, "close", None)
        if callable(close):
            close()


def _http_status_code(exc: BaseException) -> int | None:
    code = getattr(exc, "code", None)
    return int(code) if isinstance(code, int) else None


@dataclass(frozen=True)
class _BudgetReservation:
    day: str
    amount_usd: float
    input_tokens: int


class _DailyBudget:
    """Small numeric-only daily ledger for Jev input-token reservations."""

    def __init__(
        self,
        *,
        daily_limit_usd: float,
        input_token_price_usd: float,
        output_token_price_usd: float,
        budget_path: str | os.PathLike[str] | None,
        date_provider: Callable[[], str],
        token_estimator: Callable[[bytes], int],
    ) -> None:
        values = (daily_limit_usd, input_token_price_usd, output_token_price_usd)
        if any(isinstance(value, bool) or not math.isfinite(float(value)) for value in values):
            raise ValueError("budget prices and limit must be finite")
        if daily_limit_usd < 0 or input_token_price_usd < 0 or output_token_price_usd < 0:
            raise ValueError("budget prices and limit must be non-negative")
        self.daily_limit_usd = float(daily_limit_usd)
        self.input_token_price_usd = float(input_token_price_usd)
        self.output_token_price_usd = float(output_token_price_usd)
        self.budget_path = Path(budget_path).expanduser() if budget_path is not None else None
        self._date_provider = date_provider
        self._token_estimator = token_estimator
        self._lock = threading.RLock()
        self._state: dict[str, Any] | None = None

    def estimate_input_tokens(self, body: bytes) -> int:
        try:
            raw = self._token_estimator(body)
        except Exception as exc:
            raise ValueError("input token estimator failed") from exc
        if isinstance(raw, bool) or not isinstance(raw, int) or raw < 1:
            raise ValueError("input token estimator returned an invalid count")
        return raw

    def reserve(self, input_tokens: int) -> _BudgetReservation | None:
        if isinstance(input_tokens, bool) or not isinstance(input_tokens, int) or input_tokens < 1:
            raise ValueError("input token count must be positive")
        amount = float(input_tokens) * self.input_token_price_usd
        with self._lock:
            state = self._load_locked()
            used = float(state["spent_usd"]) + float(state["reserved_usd"])
            if used + amount > self.daily_limit_usd + 1e-12:
                return None
            state["reserved_usd"] = float(state["reserved_usd"]) + amount
            self._persist_locked(state)
            return _BudgetReservation(str(state["date"]), amount, input_tokens)

    def release(self, reservation: _BudgetReservation) -> None:
        """Release a reservation when no network request could be started."""

        with self._lock:
            state = self._load_locked()
            if state["date"] != reservation.day:
                return
            state["reserved_usd"] = max(
                0.0, float(state["reserved_usd"]) - reservation.amount_usd
            )
            self._persist_locked(state)

    def settle(
        self,
        reservation: _BudgetReservation,
        usage: Mapping[str, int] | None,
    ) -> None:
        """Correct a known successful usage; retain unknown reservations."""

        if usage is None or "input_tokens" not in usage:
            return
        input_tokens = usage.get("input_tokens")
        output_tokens = usage.get("output_tokens", 0)
        if (
            isinstance(input_tokens, bool)
            or not isinstance(input_tokens, int)
            or input_tokens < 0
            or isinstance(output_tokens, bool)
            or not isinstance(output_tokens, int)
            or output_tokens < 0
        ):
            return
        with self._lock:
            state = self._load_locked()
            if state["date"] != reservation.day:
                # A response crossing the configured date boundary belongs to the old
                # ledger.  The new day has already reset its reservation pool.
                return
            state["reserved_usd"] = max(
                0.0, float(state["reserved_usd"]) - reservation.amount_usd
            )
            actual = (
                float(input_tokens) * self.input_token_price_usd
                + float(output_tokens) * self.output_token_price_usd
            )
            state["spent_usd"] = float(state["spent_usd"]) + actual
            self._persist_locked(state)

    def snapshot(self) -> Mapping[str, float | str]:
        with self._lock:
            state = self._load_locked()
            return {
                "date": str(state["date"]),
                "spent_usd": float(state["spent_usd"]),
                "reserved_usd": float(state["reserved_usd"]),
                "remaining_usd": max(
                    0.0,
                    self.daily_limit_usd
                    - float(state["spent_usd"])
                    - float(state["reserved_usd"]),
                ),
            }

    def _today(self) -> str:
        day = self._date_provider()
        if not isinstance(day, str) or not day:
            raise ValueError("date provider returned an invalid day")
        return day

    def _load_locked(self) -> dict[str, Any]:
        day = self._today()
        if self._state is not None and self._state.get("date") == day:
            return self._state
        state: dict[str, Any] | None = None
        if self.budget_path is not None:
            try:
                raw = json.loads(self.budget_path.read_text(encoding="utf-8"))
            except FileNotFoundError:
                raw = None
            except (OSError, ValueError, TypeError) as exc:
                raise ValueError("budget ledger unavailable") from exc
            if raw is not None:
                if not isinstance(raw, Mapping) or not isinstance(raw.get("date"), str):
                    raise ValueError("invalid budget ledger")
                datetime.strptime(raw["date"], "%Y-%m-%d")
                if raw["date"] > day:
                    raise ValueError("budget clock moved backwards")
                for name in ("spent_usd", "reserved_usd"):
                    value = raw.get(name)
                    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
                        raise ValueError("invalid budget ledger")
                if raw["date"] == day:
                    state = {"date": day, "spent_usd": float(raw["spent_usd"]), "reserved_usd": float(raw["reserved_usd"])}
        self._state = state or {"date": day, "spent_usd": 0.0, "reserved_usd": 0.0}
        return self._state

    def _persist_locked(self, state: Mapping[str, Any]) -> None:
        if self.budget_path is None:
            return
        # This is deliberately the entire schema: date plus numbers only.  No
        # request id, candidate, context, secret, or model response is stored.
        payload = {
            "date": str(state["date"]),
            "spent_usd": round(float(state["spent_usd"]), 12),
            "reserved_usd": round(float(state["reserved_usd"]), 12),
        }
        path = self.budget_path
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        temporary = path.with_name(f".{path.name}.tmp")
        try:
            temporary.write_text(
                json.dumps(payload, ensure_ascii=True, sort_keys=True, separators=(",", ":")),
                encoding="utf-8",
            )
            os.chmod(temporary, 0o600)
            temporary.replace(path)
        finally:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass


def _default_input_token_estimator(body: bytes) -> int:
    # Jev's exact tokenizer is remote.  A conservative UTF-8 byte estimate is
    # enough for a preflight reservation; successful usage corrects it later.
    return max(4096, len(body) + 1024)


class JevProvider:
    """Asynchronous Jev adapter with verified persistent transport and guardrails."""

    provider_name = "jev"
    model_name = JEV_MODEL_ID

    def __init__(
        self,
        vault_ref: str,
        *,
        secret_reader: Callable[[str], str] | None = None,
        credential_reader: Callable[[str], str] | None = None,
        urlopen: Callable[..., Any] | None = None,
        endpoint: str = JEV_ENDPOINT,
        ssl_context: ssl.SSLContext | None = None,
        session: Any | None = None,
        transport: JevHTTPTransport | None = None,
        daily_budget_usd: float = DEFAULT_DAILY_BUDGET_USD,
        budget_usd: float | None = None,
        budget_path: str | os.PathLike[str] | None = DEFAULT_BUDGET_PATH,
        input_token_price_usd: float = DEFAULT_INPUT_TOKEN_PRICE_USD,
        output_token_price_usd: float = DEFAULT_OUTPUT_TOKEN_PRICE_USD,
        input_token_estimator: Callable[[bytes], int] | None = None,
        date_provider: Callable[[], str] | None = None,
        clock: Callable[[], float] = time.monotonic,
        wall_clock: Callable[[], float] = time.time,
        rate_limit_per_second: int = JEV_RATE_LIMIT_PER_SECOND,
        cooldown_seconds: float = JEV_COOLDOWN_SECONDS,
        max_retry_after_seconds: float = JEV_MAX_RETRY_AFTER_SECONDS,
    ) -> None:
        if not isinstance(vault_ref, str) or not vault_ref or "/" in vault_ref or ".." in vault_ref:
            raise ValueError("vault ref is required")
        if not isinstance(endpoint, str) or not endpoint.startswith("https://"):
            raise ValueError("Jev endpoint must use HTTPS")
        if isinstance(rate_limit_per_second, bool) or rate_limit_per_second < 1:
            raise ValueError("rate_limit_per_second must be positive")
        for value in (cooldown_seconds, max_retry_after_seconds):
            if isinstance(value, bool) or not math.isfinite(float(value)) or value < 0:
                raise ValueError("retry windows must be finite and non-negative")
        self.vault_ref = vault_ref
        self._secret_reader = secret_reader or credential_reader or VaultSecretReader()
        self._urlopen = urlopen
        self._endpoint = endpoint
        self._ssl_context = ssl_context or _system_ssl_context()
        self._transport = transport or JevHTTPTransport(
            session=session,
            urlopen=urlopen,
            ssl_context=self._ssl_context,
            max_response_bytes=MAX_REQUEST_BODY_BYTES,
        )
        if budget_usd is not None:
            daily_budget_usd = budget_usd
        if (
            budget_path is not None
            and Path(budget_path).expanduser() == Path(DEFAULT_BUDGET_PATH)
            and (
                urlopen is not None or session is not None or transport is not None
            )
        ):
            # Injected transports are the test/offline seam.  Do not make a
            # mock call mutate the user's default ledger unless a path was
            # explicitly supplied non-default path; the production requests path keeps the
            # persistent default.
            budget_path = None
        self._clock = clock
        self._wall_clock = wall_clock
        self._rate_limit_per_second = int(rate_limit_per_second)
        self._cooldown_seconds = float(cooldown_seconds)
        self._max_retry_after_seconds = float(max_retry_after_seconds)
        self._date_provider = date_provider or (
            lambda: datetime.now(ZoneInfo("Asia/Singapore")).date().isoformat()
        )
        self._budget = _DailyBudget(
            daily_limit_usd=daily_budget_usd,
            input_token_price_usd=input_token_price_usd,
            output_token_price_usd=output_token_price_usd,
            budget_path=budget_path,
            date_provider=self._date_provider,
            token_estimator=input_token_estimator or _default_input_token_estimator,
        )
        self._lock = threading.RLock()
        self._busy = False
        self._closing = False
        self._api_key: str | None = None
        self._credential_error: str | None = None
        self._disabled_401 = False
        self._consecutive_failures = 0
        self._cooldown_until = 0.0
        self._retry_not_before = 0.0
        self._recent_starts: deque[float] = deque()

    @property
    def status(self) -> str:
        return self.health().status

    @property
    def model(self) -> str:
        return self.model_name

    def start(self) -> None:
        return None

    def health(self) -> ProviderResult:
        started = self._clock()
        with self._lock:
            if self._closing:
                status, error = "unavailable", "runtime_closed"
            elif self._disabled_401:
                status, error = "unavailable", "http_401"
            elif self._cooldown_until > started:
                status, error = "unavailable", "cooldown"
            elif self._retry_not_before > started:
                status, error = "unavailable", "http_429"
            elif self._busy:
                status, error = "busy", None
            elif self._credential_error:
                status, error = "unavailable", self._credential_error
            else:
                status, error = "ready", None
        return _result(
            status=status,
            provider=self.provider_name,
            model=self.model_name,
            started=started,
            error=error,
        )

    def decide(self, request: DecisionRequest) -> ProviderResult:
        started = self._clock()
        if not request.candidates:
            return _result(
                status="no_match",
                provider=self.provider_name,
                model=self.model_name,
                started=started,
            )
        if len(request.candidates) + 1 > MAX_OPTIONS:
            return _result(
                status="error",
                provider=self.provider_name,
                model=self.model_name,
                started=started,
                error="invalid_request",
            )
        try:
            request_body = self._build_request_body(request)
        except (TypeError, ValueError):
            return _result(
                status="error",
                provider=self.provider_name,
                model=self.model_name,
                started=started,
                error="invalid_request",
            )
        with self._lock:
            if self._busy:
                return _result(
                    status="busy",
                    provider=self.provider_name,
                    model=self.model_name,
                    started=started,
                )
            policy_error = self._policy_error_locked(started)
            if policy_error is not None:
                return self._policy_result(policy_error, started)
            self._busy = True

        done = threading.Event()
        holder: dict[str, Any] = {}

        def run() -> None:
            try:
                holder["result"] = self._run_request(request, request_body, started)
            except CredentialUnavailable:
                with self._lock:
                    self._credential_error = "credential_unavailable"
                holder["result"] = _result(
                    status="unavailable",
                    provider=self.provider_name,
                    model=self.model_name,
                    started=started,
                    error="credential_unavailable",
                )
            except Exception:
                holder["result"] = _result(
                    status="error",
                    provider=self.provider_name,
                    model=self.model_name,
                    started=started,
                    error="transport_error",
                )
            finally:
                with self._lock:
                    self._busy = False
                done.set()

        threading.Thread(target=run, name="rime-jev-http", daemon=True).start()
        if not done.wait(timeout=max(0.0, request.max_age_ms / 1000.0)):
            return _result(
                status="error",
                provider=self.provider_name,
                model=self.model_name,
                started=started,
                error="timeout",
            )
        return holder["result"]

    def _run_request(
        self, request: DecisionRequest, request_body: bytes, started: float
    ) -> ProviderResult:
        reservation: _BudgetReservation | None = None
        attempted = False
        with self._lock:
            policy_error = self._policy_error_locked(self._clock())
            if policy_error is not None:
                return self._policy_result(policy_error, started)
        try:
            input_tokens = self._budget.estimate_input_tokens(request_body)
            with self._lock:
                # Recheck immediately before reservation and transport.  The
                # rate limiter never sleeps on the input path.
                policy_error = self._policy_error_locked(self._clock())
                if policy_error is not None:
                    return self._policy_result(policy_error, started)
                try:
                    reservation = self._budget.reserve(input_tokens)
                except (OSError, ValueError):
                    return self._policy_result("budget_unavailable", started)
                if reservation is None:
                    return self._policy_result("budget_exhausted", started)

            try:
                api_key = self._get_api_key()
            except CredentialUnavailable:
                self._budget.release(reservation)
                reservation = None
                raise

            with self._lock:
                if self._closing or self._disabled_401:
                    self._budget.release(reservation)
                    reservation = None
                    return self._policy_result(
                        "runtime_closed" if self._closing else "http_401", started
                    )
                self._recent_starts.append(self._clock())
                attempted = True

            result = self._request_once(request, request_body, api_key, started)
            if result.status in {"ready", "no_match"}:
                self._budget.settle(reservation, result.usage)
            self._record_outcome(result)
            return result
        except CredentialUnavailable:
            raise
        except (OSError, ValueError):
            result = _result(
                status="error",
                provider=self.provider_name,
                model=self.model_name,
                started=started,
                error="transport_error",
            )
            if reservation is not None:
                if not attempted:
                    self._budget.release(reservation)
                self._record_outcome(result)
            return result
        except Exception:
            # An injected transport may use a provider-specific exception type;
            # it is still a transport failure and must count toward cooldown.
            result = _result(
                status="error",
                provider=self.provider_name,
                model=self.model_name,
                started=started,
                error="transport_error",
            )
            if reservation is not None:
                if not attempted:
                    self._budget.release(reservation)
                self._record_outcome(result)
            return result

    def _request_once(
        self,
        request: DecisionRequest,
        request_body: bytes,
        api_key: str,
        started: float,
    ) -> ProviderResult:
        labels = tuple(str(index) for index in range(len(request.candidates))) + ("none",)
        try:
            response = self._transport.post(
                self._endpoint,
                body=request_body,
                headers={
                    "Authorization": f"Bearer {api_key}",
                    "Content-Type": "application/json",
                    "Accept": "application/json",
                },
                timeout=max(0.001, request.max_age_ms / 1000.0),
            )
            if response.status_code >= 400:
                return self._http_failure(response.status_code, response.headers, started)
            if response.status_code >= 300:
                return self._http_failure(response.status_code, response.headers, started)
            payload = json.loads(response.body.decode("utf-8"))
        except HTTPTransportError as exc:
            return self._http_failure(exc.status_code, exc.headers, started)
        except (TimeoutError, socket.timeout):
            return _result(
                status="error",
                provider=self.provider_name,
                model=self.model_name,
                started=started,
                error="timeout",
            )
        except (urllib.error.URLError, OSError, ValueError, UnicodeError, json.JSONDecodeError):
            return _result(
                status="error",
                provider=self.provider_name,
                model=self.model_name,
                started=started,
                error="transport_error",
            )

        try:
            choice_label, raw_probabilities, usage = self._validate_response(payload, labels)
            probabilities = _validate_probabilities(labels, raw_probabilities)[0]
            mapped = _mapped_probabilities(request, labels, probabilities)
        except (TypeError, ValueError, KeyError, IndexError):
            return _result(
                status="error",
                provider=self.provider_name,
                model=self.model_name,
                started=started,
                error="bad_response",
            )
        if choice_label == "none":
            return _result(
                status="no_match",
                provider=self.provider_name,
                model=self.model_name,
                started=started,
                probabilities=mapped,
                usage=usage,
            )
        choice_index = int(choice_label)
        return _result(
            status="ready",
            provider=self.provider_name,
            model=self.model_name,
            started=started,
            choice_id=request.candidates[choice_index].id,
            probabilities=mapped,
            usage=usage,
        )

    def _build_request_body(self, request: DecisionRequest) -> bytes:
        criteria = {
            str(index): (
                f"id={candidate.id}; text={candidate.text}; continuation={request.context}{candidate.text}"
                if request.abbreviated else f"id={candidate.id}; text={candidate.text}"
            )
            for index, candidate in enumerate(request.candidates)
        }
        criteria["none"] = (
            "Use none only when every declared candidate is inapplicable; "
            "uncertainty about the user's intent alone is not a reason to choose none."
        )
        body = {
            "state": {"context": request.context, "pinyin": request.pinyin},
            "model": self.model_name,
            "questions": {
                "candidate": {
                    "type": "choice",
                    "instructions": _decision_instruction(request),
                    "criteria": criteria,
                }
            },
        }
        encoded = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        if len(encoded) > MAX_REQUEST_BODY_BYTES:
            raise ValueError("request body too large")
        return encoded

    def _policy_error_locked(self, now: float) -> str | None:
        if self._closing:
            return "runtime_closed"
        if self._disabled_401:
            return "http_401"
        if self._credential_error:
            return self._credential_error
        if self._cooldown_until > now:
            return "cooldown"
        if self._retry_not_before > now:
            return "http_429"
        self._trim_recent_starts_locked(now)
        if len(self._recent_starts) >= self._rate_limit_per_second:
            return "rate_limited"
        return None

    def _policy_result(self, error: str, started: float) -> ProviderResult:
        return _result(
            status="unavailable",
            provider=self.provider_name,
            model=self.model_name,
            started=started,
            error=error,
        )

    def _trim_recent_starts_locked(self, now: float) -> None:
        cutoff = now - 1.0
        while self._recent_starts and self._recent_starts[0] <= cutoff:
            self._recent_starts.popleft()

    def _http_failure(
        self,
        status_code: int,
        headers: Mapping[str, str],
        started: float,
    ) -> ProviderResult:
        if status_code == 401:
            error = "http_401"
        elif status_code == 429:
            delay = _retry_after_seconds(
                headers,
                default_seconds=JEV_DEFAULT_RETRY_AFTER_SECONDS,
                max_seconds=self._max_retry_after_seconds,
                wall_clock=self._wall_clock,
            )
            with self._lock:
                self._retry_not_before = max(self._retry_not_before, self._clock() + delay)
            error = "http_429"
        elif status_code == 529 or status_code >= 500:
            error = "http_5xx"
        else:
            error = "http_4xx"
        return _result(
            status="error",
            provider=self.provider_name,
            model=self.model_name,
            started=started,
            error=error,
        )

    def _record_outcome(self, result: ProviderResult) -> None:
        with self._lock:
            if result.error == "http_401":
                self._disabled_401 = True
                self._credential_error = "http_401"
                self._api_key = None
                return
            if result.error in {"transport_error", "timeout", "http_5xx"}:
                self._consecutive_failures += 1
                if self._consecutive_failures >= 3:
                    self._cooldown_until = max(
                        self._cooldown_until, self._clock() + self._cooldown_seconds
                    )
                    self._consecutive_failures = 0
                return
            self._consecutive_failures = 0

    def budget_snapshot(self) -> Mapping[str, float | str]:
        """Return date and numeric budget counters without request content."""

        return self._budget.snapshot()

    def _get_api_key(self) -> str:
        with self._lock:
            if self._api_key:
                return self._api_key
        try:
            value = self._secret_reader(self.vault_ref)
        except CredentialUnavailable:
            raise
        except Exception as exc:
            raise CredentialUnavailable from exc
        if not isinstance(value, str) or not value:
            raise CredentialUnavailable
        with self._lock:
            if self._closing or self._disabled_401:
                raise CredentialUnavailable
            self._api_key = value
        return value

    def _validate_response(
        self, payload: Any, labels: Sequence[str]
    ) -> tuple[str, Mapping[str, Any], Mapping[str, int] | None]:
        if not isinstance(payload, Mapping) or payload.get("model") != self.model_name:
            raise ValueError
        answers = payload.get("answers")
        if not isinstance(answers, Mapping):
            raise ValueError
        answer = answers.get("candidate")
        if not isinstance(answer, Mapping) or answer.get("type") != "choice":
            raise ValueError
        choice = answer.get("choice")
        if not isinstance(choice, str) or choice not in labels:
            raise ValueError
        probabilities = answer.get("probabilities")
        _validate_probabilities(labels, probabilities)
        usage = _safe_usage(payload.get("usage"))
        return choice, probabilities, usage

    def shutdown(self) -> None:
        with self._lock:
            if self._closing:
                return
            self._closing = True
            self._api_key = None
            self._credential_error = "runtime_closed"
        close = getattr(self._transport, "close", None)
        if callable(close):
            close()


def _retry_after_seconds(
    headers: Mapping[str, str],
    *,
    default_seconds: float,
    max_seconds: float,
    wall_clock: Callable[[], float],
) -> float:
    raw: str | None = None
    for key, value in headers.items():
        if str(key).lower() == "retry-after":
            raw = str(value).strip()
            break
    if not raw:
        delay = default_seconds
    else:
        try:
            delay = float(raw)
        except ValueError:
            try:
                parsed = parsedate_to_datetime(raw)
                delay = parsed.timestamp() - wall_clock()
            except (TypeError, ValueError, OverflowError):
                delay = default_seconds
    if not math.isfinite(delay):
        delay = default_seconds
    return min(max(0.0, delay), max_seconds)


def _safe_usage(value: Any) -> dict[str, int] | None:
    if value is None:
        return None
    if not isinstance(value, Mapping):
        raise ValueError
    out: dict[str, int] = {}
    for key in ("input_tokens", "output_tokens"):
        raw = value.get(key)
        if raw is None:
            continue
        if isinstance(raw, bool) or not isinstance(raw, int) or raw < 0:
            raise ValueError
        out[key] = raw
    return out or None


__all__ = [
    "Candidate",
    "DECISION_INSTRUCTION",
    "DecisionRequest",
    "DEFAULT_DAILY_BUDGET_USD",
    "DEFAULT_INPUT_TOKEN_PRICE_USD",
    "JEV_COOLDOWN_SECONDS",
    "JevProvider",
    "JEV_MAX_RETRY_AFTER_SECONDS",
    "JEV_RATE_LIMIT_PER_SECOND",
    "LocalProvider",
    "ProviderInputError",
    "ProviderResult",
    "VaultSecretReader",
    "trim_state_to_token_limit",
]
