from __future__ import annotations

import json
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import rime_jev.providers as providers  # noqa: E402
from rime_jev.providers import (  # noqa: E402
    DECISION_INSTRUCTION,
    JEV_ENDPOINT,
    JEV_MODEL_ID,
    LOCAL_MODEL_ID,
    WARMUP_STATE,
    Candidate,
    DecisionRequest,
    JevProvider,
    LocalProvider,
    ProviderInputError,
    trim_state_to_token_limit,
)


class FakeTokenizer:
    def encode(self, text: str, add_special_tokens: bool = False) -> list[int]:
        return [ord(char) for char in text]

    def decode(self, tokens: list[int], skip_special_tokens: bool = True) -> str:
        return "".join(chr(token) for token in tokens)


class FakeDecision:
    def __init__(self, options, index: int, probabilities):
        self.options = tuple(options)
        self.index = index
        self.probabilities = tuple(probabilities)


class FakeDecider:
    def __init__(self, *, block: threading.Event | None = None, bad: str | None = None):
        self.tokenizer = FakeTokenizer()
        self.block = block
        self.bad = bad
        self.calls: list[tuple[str, tuple[str, ...]]] = []
        self.inference_started = threading.Event()

    def decide(self, state, question, *, max_state_tokens):
        options = tuple(question.options)
        self.calls.append((state, options))
        if state != WARMUP_STATE:
            self.inference_started.set()
            if self.block is not None:
                self.block.wait(timeout=2)
        if self.bad == "ids":
            return FakeDecision(("wrong", "options"), 0, (0.5, 0.5))
        if self.bad == "probabilities":
            return FakeDecision(options, 0, (float("nan"),) + (0.0,) * (len(options) - 1))
        probabilities = [0.0] * len(options)
        probabilities[0] = 1.0
        return FakeDecision(options, 0, probabilities)


def request() -> DecisionRequest:
    return DecisionRequest(
        request_id="r1",
        context="old context",
        pinyin="youxiang",
        candidates=(Candidate("邮箱", "邮箱"), Candidate("油箱", "油箱")),
        max_age_ms=1000,
    )


def wait_ready(provider: LocalProvider) -> None:
    assert provider.wait_until_ready(timeout=1)
    assert provider.health().status == "ready"


def test_local_loading_is_async_and_loading_request_returns_immediately():
    load_started = threading.Event()
    release_load = threading.Event()
    decider = FakeDecider()

    def loader(path):
        load_started.set()
        release_load.wait(timeout=2)
        return decider

    provider = LocalProvider("/offline/model", loader=loader, warmup=False)
    provider.start()
    assert load_started.wait(timeout=1)

    started = time.monotonic()
    result = provider.decide(request())
    elapsed = time.monotonic() - started
    assert result.status == "loading"
    assert elapsed < 0.2
    assert provider.health().status == "loading"

    release_load.set()
    wait_ready(provider)
    provider.shutdown()


def test_local_loading_warms_up_with_fixed_non_sensitive_question():
    decider = FakeDecider()
    provider = LocalProvider("/offline/model", loader=lambda path: decider)
    provider.start()
    wait_ready(provider)

    assert decider.calls
    warmup_state, warmup_options = decider.calls[0]
    assert warmup_state == WARMUP_STATE
    assert warmup_options == ("ready", "not_ready")
    assert provider.decide(request()).status == "ready"
    provider.shutdown()


def test_local_question_uses_the_shared_context_and_intent_instruction(monkeypatch):
    class CapturedQuestion:
        def __init__(self, instruction, options):
            self.instruction = instruction
            self.options = tuple(options)

    monkeypatch.setattr(providers, "Question", CapturedQuestion)
    question = providers._build_local_question(request())

    assert question.instruction == DECISION_INSTRUCTION
    assert "state.context" in question.instruction
    assert "user's intent" in question.instruction
    assert "uncertainty" in question.instruction


def test_local_inference_has_one_task_and_returns_busy_without_queueing():
    release = threading.Event()
    decider = FakeDecider(block=release)
    provider = LocalProvider("/offline/model", loader=lambda path: decider, warmup=False)
    provider.start()
    wait_ready(provider)

    first_result: list = []
    first = threading.Thread(target=lambda: first_result.append(provider.decide(request())))
    first.start()
    assert decider.inference_started.wait(timeout=1)

    second = provider.decide(request())
    assert second.status == "busy"
    release.set()
    first.join(timeout=2)
    assert first_result and first_result[0].status == "ready"
    provider.shutdown()


def test_local_timeout_does_not_start_a_second_inference():
    release = threading.Event()
    decider = FakeDecider(block=release)
    provider = LocalProvider("/offline/model", loader=lambda path: decider, warmup=False)
    provider.start()
    wait_ready(provider)

    timed_out_request = DecisionRequest(
        request_id="timeout",
        context="context",
        pinyin="pinyin",
        candidates=(Candidate("a", "甲"),),
        max_age_ms=10,
    )
    result = provider.decide(timed_out_request)
    assert result.status == "error"
    assert result.error == "timeout"
    assert provider.decide(request()).status == "busy"
    release.set()
    provider.shutdown()


def test_local_unloads_when_idle_and_wakes_asynchronously():
    decider = FakeDecider()
    provider = LocalProvider("/offline/model", loader=lambda path: decider, warmup=False, idle_seconds=0)
    provider.start()
    wait_ready(provider)
    assert provider.unload_if_idle()
    assert provider.health().status == "unavailable"
    assert provider.decide(request()).status == "loading"
    provider.shutdown()


@pytest.mark.parametrize("bad", ["ids", "probabilities"])
def test_local_rejects_bad_decision_ids_and_probabilities(bad):
    decider = FakeDecider(bad=bad)
    provider = LocalProvider("/offline/model", loader=lambda path: decider, warmup=False)
    provider.start()
    wait_ready(provider)

    result = provider.decide(request())
    assert result.status == "error"
    assert result.error == "bad_response"
    assert "details" not in result.to_dict("r1")
    provider.shutdown()


def test_local_builds_unique_id_text_options_and_keeps_none_at_255_limit():
    seen: list[tuple[str, ...]] = []
    decider = FakeDecider()

    def loader(path):
        original_decide = decider.decide

        def capture(state, question, *, max_state_tokens):
            if state != WARMUP_STATE:
                seen.append(tuple(question.options))
            return original_decide(state, question, max_state_tokens=max_state_tokens)

        decider.decide = capture
        return decider

    candidates = tuple(Candidate(f"id-{i}", f"词{i}") for i in range(254))
    large_request = DecisionRequest(
        request_id="large",
        context="context",
        pinyin="pin",
        candidates=candidates,
        max_age_ms=1000,
    )
    provider = LocalProvider("/offline/model", loader=loader, warmup=False)
    provider.start()
    wait_ready(provider)
    result = provider.decide(large_request)
    assert result.status == "ready"
    assert seen and len(seen[0]) == 255
    assert len(set(seen[0])) == 255
    assert '"id": "id-0"' in seen[0][0]
    assert '"id": "none"' in seen[0][-1]
    provider.shutdown()


def test_state_trimming_drops_old_context_before_the_current_pinyin():
    trimmed = trim_state_to_token_limit(
        FakeTokenizer(), "OLD-" * 20 + "new-context", "youxiang", max_tokens=32
    )
    assert "OLD-OLD-" not in trimmed
    assert "pinyin: youxiang" in trimmed


def test_decision_request_rejects_more_than_254_candidates():
    payload = {
        "id": "too-many",
        "state": {"context": "", "pinyin": "p"},
        "candidates": [{"id": str(i), "text": str(i)} for i in range(255)],
    }
    with pytest.raises(ProviderInputError):
        DecisionRequest.from_payload(payload)


class FakeHTTPResponse:
    def __init__(self, payload: dict):
        self._raw = json.dumps(payload).encode("utf-8")
        self.closed = False

    def read(self, size=-1):
        raw, self._raw = self._raw[:size], self._raw[size:]
        return raw

    def close(self):
        self.closed = True


def test_jev_adapter_uses_fixed_model_endpoint_and_maps_mock_response(tmp_path):
    seen: dict[str, object] = {}
    labels = ("0", "1", "none")
    response = FakeHTTPResponse(
        {
            "model": JEV_MODEL_ID,
            "answers": {
                "candidate": {
                    "type": "choice",
                    "choice": "1",
                    "probabilities": {"0": 0.1, "1": 0.8, "none": 0.1},
                }
            },
            "usage": {"input_tokens": 20, "output_tokens": 3},
        }
    )

    def urlopen(http_request, *, timeout, context):
        seen["url"] = http_request.full_url
        seen["headers"] = dict(http_request.headers)
        seen["body"] = json.loads(http_request.data.decode("utf-8"))
        seen["timeout"] = timeout
        return response

    provider = JevProvider(
        "test.typesafe_api_key",
        secret_reader=lambda ref: "mock-api-key",
        urlopen=urlopen,
        budget_path=tmp_path / "budget.json",
    )
    result = provider.decide(request())

    assert result.status == "ready"
    assert result.choice_id == "油箱"
    assert result.probabilities == {"邮箱": 0.1, "油箱": 0.8, "none": 0.1}
    assert seen["url"] == JEV_ENDPOINT
    assert seen["body"]["model"] == JEV_MODEL_ID
    assert seen["body"]["questions"]["candidate"]["type"] == "choice"
    assert seen["body"]["questions"]["candidate"]["instructions"] == DECISION_INSTRUCTION
    assert set(seen["body"]["questions"]["candidate"]["criteria"]) == set(labels)
    assert seen["headers"]["Authorization"] == "Bearer mock-api-key"
    assert result.usage == {"input_tokens": 20, "output_tokens": 3}
    provider.shutdown()


def test_jev_adapter_rejects_bad_probability_ids_without_response_payload(tmp_path):
    response = FakeHTTPResponse(
        {
            "model": JEV_MODEL_ID,
            "answers": {
                "candidate": {
                    "type": "choice",
                    "choice": "0",
                    "probabilities": {"0": 1.0, "wrong": 0.0, "none": 0.0},
                }
            },
        }
    )
    provider = JevProvider(
        "confirmed.ref",
        secret_reader=lambda ref: "mock-api-key",
        urlopen=lambda *a, **k: response,
        budget_path=tmp_path / "budget.json",
    )
    result = provider.decide(request())
    assert result.status == "error"
    assert result.error == "bad_response"
    assert "details" not in result.to_dict("r1")
    provider.shutdown()


class FakeSession:
    def __init__(self, response_body: bytes):
        self.response_body = response_body
        self.calls: list[dict[str, object]] = []
        self.closed = False

    def post(self, endpoint, **kwargs):
        self.calls.append({"endpoint": endpoint, **kwargs})
        return type(
            "Response",
            (),
            {"status_code": 200, "headers": {}, "content": self.response_body},
        )()

    def close(self):
        self.closed = True


def jev_success_payload(*, usage=None):
    payload = {
        "model": JEV_MODEL_ID,
        "answers": {
            "candidate": {
                "type": "choice",
                "choice": "0",
                "probabilities": {"0": 1.0, "1": 0.0, "none": 0.0},
            }
        },
    }
    if usage is not None:
        payload["usage"] = usage
    return json.dumps(payload).encode("utf-8")


class FakeClock:
    def __init__(self, value=0.0):
        self.value = value

    def __call__(self):
        return self.value

    def advance(self, seconds):
        self.value += seconds


def test_jev_provider_reuses_one_injected_session_and_closes_it(tmp_path):
    session = FakeSession(jev_success_payload(usage={"input_tokens": 1}))
    provider = JevProvider(
        "confirmed.ref",
        secret_reader=lambda ref: "mock-api-key",
        session=session,
        budget_path=tmp_path / "budget.json",
        input_token_estimator=lambda body: 1,
        input_token_price_usd=0.001,
    )

    assert provider.decide(request()).status == "ready"
    assert provider.decide(request()).status == "ready"
    assert len(session.calls) == 2
    assert all(call["allow_redirects"] is False for call in session.calls)
    assert all(call["verify"] is True for call in session.calls)
    provider.shutdown()
    assert session.closed


def test_jev_rate_limit_is_nonblocking_and_does_not_cross_provider(tmp_path):
    attempts = 0

    def urlopen(*args, **kwargs):
        nonlocal attempts
        attempts += 1
        return FakeHTTPResponse(json.loads(json.dumps({
            "model": JEV_MODEL_ID,
            "answers": {
                "candidate": {
                    "type": "choice",
                    "choice": "0",
                    "probabilities": {"0": 1.0, "1": 0.0, "none": 0.0},
                }
            },
        })))

    clock = FakeClock()
    provider = JevProvider(
        "confirmed.ref",
        secret_reader=lambda ref: "mock-api-key",
        urlopen=urlopen,
        clock=clock,
        budget_path=tmp_path / "budget.json",
        input_token_estimator=lambda body: 1,
        input_token_price_usd=0.001,
    )
    for _ in range(4):
        assert provider.decide(request()).status == "ready"
    started = time.monotonic()
    limited = provider.decide(request())
    assert limited.error == "rate_limited"
    assert time.monotonic() - started < 0.2
    assert attempts == 4
    clock.advance(1.01)
    assert provider.decide(request()).status == "ready"
    provider.shutdown()


def test_jev_three_transport_failures_enter_cooldown_without_retry_sleep(tmp_path):
    attempts = 0
    clock = FakeClock()

    def urlopen(*args, **kwargs):
        nonlocal attempts
        attempts += 1
        raise OSError("offline")

    provider = JevProvider(
        "confirmed.ref",
        secret_reader=lambda ref: "mock-api-key",
        urlopen=urlopen,
        clock=clock,
        rate_limit_per_second=100,
        budget_path=tmp_path / "budget.json",
        input_token_estimator=lambda body: 1,
        input_token_price_usd=0.001,
    )
    for _ in range(3):
        assert provider.decide(request()).error == "transport_error"
    assert provider.health().error == "cooldown"
    assert provider.decide(request()).error == "cooldown"
    assert attempts == 3
    clock.advance(30.01)
    provider.shutdown()


def test_jev_401_is_disabled_until_a_fresh_provider(tmp_path):
    attempts = 0

    def urlopen(*args, **kwargs):
        nonlocal attempts
        attempts += 1
        raise urllib.error.HTTPError(
            JEV_ENDPOINT, 401, "unauthorized", {}, None
        )

    provider = JevProvider(
        "confirmed.ref",
        secret_reader=lambda ref: "mock-api-key",
        urlopen=urlopen,
        budget_path=tmp_path / "budget.json",
        input_token_estimator=lambda body: 1,
        input_token_price_usd=0.001,
    )
    assert provider.decide(request()).error == "http_401"
    assert provider.decide(request()).error == "http_401"
    assert attempts == 1
    provider.shutdown()


def test_jev_429_honors_retry_after_with_an_upper_bound(tmp_path):
    clock = FakeClock()
    calls = 0

    def urlopen(*args, **kwargs):
        nonlocal calls
        calls += 1
        if calls == 1:
            raise urllib.error.HTTPError(
                JEV_ENDPOINT, 429, "too many", {"Retry-After": "999"}, None
            )
        return FakeHTTPResponse(json.loads(jev_success_payload()))

    provider = JevProvider(
        "confirmed.ref",
        secret_reader=lambda ref: "mock-api-key",
        urlopen=urlopen,
        clock=clock,
        max_retry_after_seconds=5.0,
        budget_path=tmp_path / "budget.json",
        input_token_estimator=lambda body: 1,
        input_token_price_usd=0.001,
    )
    assert provider.decide(request()).error == "http_429"
    assert provider.decide(request()).error == "http_429"
    clock.advance(5.01)
    assert provider.decide(request()).status == "ready"
    assert calls == 2
    provider.shutdown()


def test_jev_budget_reserves_before_send_corrects_known_usage_and_stores_numbers_only(tmp_path):
    calls = 0

    def urlopen(*args, **kwargs):
        nonlocal calls
        calls += 1
        if calls == 1:
            return FakeHTTPResponse(json.loads(jev_success_payload(usage={"input_tokens": 2})))
        return FakeHTTPResponse(json.loads(jev_success_payload()))

    budget_path = tmp_path / "budget.json"
    provider = JevProvider(
        "confirmed.ref",
        secret_reader=lambda ref: "mock-api-key",
        urlopen=urlopen,
        daily_budget_usd=0.15,
        budget_path=budget_path,
        input_token_estimator=lambda body: 10,
        input_token_price_usd=0.01,
        rate_limit_per_second=100,
        date_provider=lambda: "2026-10-10",
    )
    assert provider.decide(request()).status == "ready"
    assert provider.decide(request()).status == "ready"
    blocked = provider.decide(request())
    assert blocked.error == "budget_exhausted"
    assert calls == 2
    stored = json.loads(budget_path.read_text(encoding="utf-8"))
    assert set(stored) == {"date", "spent_usd", "reserved_usd"}
    assert stored["date"] == "2026-10-10"
    assert stored["spent_usd"] == pytest.approx(0.02)
    assert stored["reserved_usd"] == pytest.approx(0.1)
    assert "youxiang" not in budget_path.read_text(encoding="utf-8")
    provider.shutdown()


def test_vault_default_opener_rejects_redirects():
    reader = providers.VaultSecretReader(vault_url="https://vault.example.test")
    handler = next(
        handler
        for handler in reader._opener.handlers
        if isinstance(handler, urllib.request.HTTPRedirectHandler)
    )
    request_object = urllib.request.Request("https://vault.example.test/api/v1/secrets/ref")
    with pytest.raises(urllib.error.HTTPError):
        handler.redirect_request(request_object, None, 302, "redirect", {}, "https://evil.test")


def test_abbreviated_spelling_is_explicit_and_uses_complete_continuations(tmp_path, monkeypatch):
    class CapturedQuestion:
        def __init__(self, instruction, options):
            self.instruction = instruction
            self.options = tuple(options)

    monkeypatch.setattr(providers, "Question", CapturedQuestion)
    payload = {
        "id": "initials", "state": {"context": "这个项目需要", "pinyin": "sj", "abbreviated": True},
        "candidates": [{"id": "first", "text": "设计"}, {"id": "second", "text": "审计"}],
    }
    req = DecisionRequest.from_payload(payload)
    assert req.abbreviated is True
    provider = JevProvider("test.ref", secret_reader=lambda _: "unused", budget_path=tmp_path / "budget.json")
    body = json.loads(provider._build_request_body(req))
    question = body["questions"]["candidate"]
    assert question["instructions"] == providers.ABBREVIATED_INSTRUCTION
    assert question["criteria"]["1"].endswith("continuation=这个项目需要审计")
    assert providers._build_local_question(req).instruction == providers.ABBREVIATED_INSTRUCTION
    del payload["state"]["abbreviated"]
    full = DecisionRequest.from_payload(payload)
    assert full.abbreviated is False
    ordinary = json.loads(provider._build_request_body(full))["questions"]["candidate"]
    assert ordinary["instructions"] == DECISION_INSTRUCTION
    assert ordinary["criteria"]["1"] == "id=second; text=审计"
    for invalid in ["true", 1, None]:
        payload["state"]["abbreviated"] = invalid
        with pytest.raises(ProviderInputError):
            DecisionRequest.from_payload(payload)
