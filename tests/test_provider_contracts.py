from __future__ import annotations

import io
import json
import sys
import threading
import time
import urllib.error
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from rime_jev.providers import (  # noqa: E402
    JEV_MODEL_ID,
    Candidate,
    DecisionRequest,
    JevProvider,
    LocalProvider,
)


class ContractTokenizer:
    def encode(self, text: str, add_special_tokens: bool = False) -> list[int]:
        return [ord(char) for char in text]

    def decode(self, tokens: list[int], skip_special_tokens: bool = True) -> str:
        return "".join(chr(token) for token in tokens)


class ModelDecision:
    def __init__(self, options, index: int, probabilities) -> None:
        self.options = tuple(options)
        self.index = index
        self.probabilities = tuple(probabilities)


class ScriptedDecider:
    tokenizer = ContractTokenizer()

    def __init__(self, *actions: str) -> None:
        self.actions = list(actions)
        self.calls = 0
        self.inference_started = threading.Event()
        self.first_call_finished = threading.Event()
        self.release = threading.Event()

    def decide(self, _state, question, *, max_state_tokens):
        action = self.actions[min(self.calls, len(self.actions) - 1)]
        self.calls += 1
        options = tuple(question.options)
        if action == "timeout":
            self.inference_started.set()
            self.release.wait(timeout=2)
            self.first_call_finished.set()
            action = "good"
        if action == "bad_probabilities":
            probabilities = (float("nan"),) + (0.0,) * (len(options) - 1)
            return ModelDecision(options, 0, probabilities)
        if action == "bad_options":
            probabilities = (1.0,) + (0.0,) * (len(options) - 1)
            return ModelDecision(tuple(reversed(options)), 0, probabilities)
        if action != "good":
            raise AssertionError(f"unknown scripted action: {action}")
        probabilities = (1.0,) + (0.0,) * (len(options) - 1)
        return ModelDecision(options, 0, probabilities)


def _request(*, max_age_ms: int = 500) -> DecisionRequest:
    return DecisionRequest(
        request_id="provider-contract",
        context="前文上下文",
        pinyin="youxiang",
        candidates=(Candidate("mail", "邮箱"), Candidate("tank", "油箱")),
        max_age_ms=max_age_ms,
    )


def _ready_local(decider: ScriptedDecider) -> LocalProvider:
    provider = LocalProvider(
        "/offline/model-do-not-download",
        loader=lambda _path: decider,
        warmup=False,
    )
    provider.start()
    assert provider.wait_until_ready(timeout=1)
    return provider


def test_local_model_load_failure_is_explicit_and_does_not_fallback():
    load_calls: list[str] = []

    def loader(path):
        load_calls.append(str(path))
        raise RuntimeError("model-load-private-marker")

    provider = LocalProvider("/offline/model-do-not-download", loader=loader, warmup=False)
    provider.start()
    assert not provider.wait_until_ready(timeout=1)

    health = provider.health()
    result = provider.decide(_request())
    provider.shutdown()

    assert load_calls == ["/offline/model-do-not-download"]
    assert health.status == "unavailable"
    assert health.error == "model_load_failed"
    assert result.status == "unavailable"
    assert result.error == "model_load_failed"
    assert "model-load-private-marker" not in str(result.to_dict(_request().id))


@pytest.mark.parametrize("bad_action", ["bad_probabilities", "bad_options"])
def test_invalid_local_model_result_is_classified_and_next_result_recovers(bad_action):
    decider = ScriptedDecider(bad_action, "good")
    provider = _ready_local(decider)
    try:
        first = provider.decide(_request())
        second = provider.decide(_request())
    finally:
        provider.shutdown()

    assert first.status == "error"
    assert first.error == "bad_response"
    assert second.status == "ready"
    assert second.choice_id == "mail"
    assert "details" not in first.to_dict(_request().id)


def test_local_timeout_releases_gate_and_subsequent_decision_recovers():
    decider = ScriptedDecider("timeout", "good")
    provider = _ready_local(decider)
    try:
        timed_out = provider.decide(_request(max_age_ms=10))
        assert decider.inference_started.wait(timeout=1)
        assert timed_out.status == "error"
        assert timed_out.error == "timeout"

        decider.release.set()
        assert decider.first_call_finished.wait(timeout=1)
        deadline = time.monotonic() + 1
        while provider.health().status == "busy" and time.monotonic() < deadline:
            time.sleep(0.01)

        recovered = provider.decide(_request())
    finally:
        decider.release.set()
        provider.shutdown()

    assert recovered.status == "ready"
    assert recovered.choice_id == "mail"


@pytest.mark.parametrize(
    ("status", "expected"),
    [
        (401, "http_401"),
        (429, "http_429"),
        (500, "http_5xx"),
        (503, "http_5xx"),
    ],
)
def test_jev_http_failures_are_classified_without_upstream_body(status, expected, capsys):
    marker = f"upstream-body-secret-{status}"

    def urlopen(*_args, **_kwargs):
        raise urllib.error.HTTPError(
            "https://api.test/jev",
            status,
            marker,
            {"Content-Type": "text/plain"},
            io.BytesIO(marker.encode()),
        )

    provider = JevProvider(
        "confirmed.typesafe_key",
        secret_reader=lambda _ref: "mock-api-key",
        urlopen=urlopen,
    )
    result = provider.decide(_request())
    provider.shutdown()

    wire = json.dumps(result.to_dict(_request().id), ensure_ascii=False)
    captured = capsys.readouterr()
    assert result.status == "error"
    assert result.error == expected
    assert marker not in wire
    assert marker not in captured.out + captured.err
    assert "details" not in result.to_dict(_request().id)
