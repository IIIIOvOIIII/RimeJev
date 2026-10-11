from __future__ import annotations

import json
import math
import shutil
import socket
import sys
import tempfile
import threading
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from rime_jev.http_transport import (  # noqa: E402
    HTTPResponse,
    JevHTTPTransport,
    MAX_RESPONSE_BYTES,
)
from rime_jev.providers import (  # noqa: E402
    JEV_MODEL_ID,
    MAX_REQUEST_BODY_BYTES,
    MAX_STATE_TOKENS,
    Candidate,
    DecisionRequest,
    JevProvider,
    LocalProvider,
    ProviderInputError,
    ProviderResult,
)
from rime_jev.runtime import MAX_MESSAGE_BYTES, RuntimeServer  # noqa: E402


def _payload(**overrides):
    payload = {
        "id": "validation-contract",
        "op": "decide",
        "state": {"context": "前文上下文", "pinyin": "youxiang"},
        "candidates": [
            {"id": "mail", "text": "邮箱"},
            {"id": "tank", "text": "油箱"},
        ],
        "max_age_ms": 500,
    }
    payload.update(overrides)
    return payload


def _request(*, context: str = "前文上下文", pinyin: str = "youxiang", max_age_ms: int = 500):
    return DecisionRequest(
        request_id="validation-contract",
        context=context,
        pinyin=pinyin,
        candidates=(Candidate("mail", "邮箱"), Candidate("tank", "油箱")),
        max_age_ms=max_age_ms,
    )


@pytest.mark.parametrize(
    "bad_state",
    [None, [], "not-an-object", 7, True],
    ids=["null", "array", "string", "number", "bool"],
)
def test_decision_request_rejects_non_object_state(bad_state):
    with pytest.raises(ProviderInputError) as caught:
        DecisionRequest.from_payload(_payload(state=bad_state))

    assert caught.value.code == "invalid_request"


@pytest.mark.parametrize(
    "candidates",
    [
        [
            {"id": "same", "text": "甲"},
            {"id": "same", "text": "乙"},
        ],
        [{"id": "none", "text": "保留词不能作为候选 ID"}],
    ],
    ids=["duplicate-id", "reserved-none-id"],
)
def test_decision_request_rejects_duplicate_or_reserved_candidate_ids(candidates):
    with pytest.raises(ProviderInputError) as caught:
        DecisionRequest.from_payload(_payload(candidates=candidates))

    assert caught.value.code == "invalid_request"


@pytest.mark.parametrize(
    "bad_age",
    [math.nan, math.inf, -math.inf, True, -1],
    ids=["nan", "positive-infinity", "negative-infinity", "bool", "negative"],
)
def test_decision_request_rejects_non_finite_bool_or_negative_age(bad_age):
    with pytest.raises(ProviderInputError) as caught:
        DecisionRequest.from_payload(_payload(max_age_ms=bad_age))

    assert caught.value.code == "invalid_request"


@pytest.mark.parametrize(
    ("location", "value"),
    [
        ("context", 123),
        ("pinyin", ["you", "xiang"]),
        ("candidate_text", {"text": "邮箱"}),
    ],
    ids=["context-number", "pinyin-array", "candidate-text-object"],
)
def test_decision_request_rejects_non_string_text_fields(location, value):
    payload = _payload()
    if location == "candidate_text":
        payload["candidates"][0]["text"] = value
    else:
        payload["state"][location] = value

    with pytest.raises(ProviderInputError) as caught:
        DecisionRequest.from_payload(payload)

    assert caught.value.code == "invalid_request"


class _RecordingRuntimeProvider:
    provider_name = "mock"
    model_name = "mock-model"

    def __init__(self):
        self.started = False
        self.closed = False
        self.calls: list[DecisionRequest] = []

    def start(self):
        self.started = True

    def health(self):
        return ProviderResult(
            status="unavailable" if self.closed else "ready",
            provider=self.provider_name,
            model=self.model_name,
            error="runtime_closed" if self.closed else None,
        )

    def decide(self, request: DecisionRequest):
        self.calls.append(request)
        return ProviderResult(
            status="ready",
            provider=self.provider_name,
            model=self.model_name,
            choice_id=request.candidates[0].id,
            probabilities={request.candidates[0].id: 1.0, "none": 0.0},
        )

    def shutdown(self):
        self.closed = True


def _wait_for_socket(path: Path):
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        if path.exists():
            return
        time.sleep(0.01)
    raise AssertionError("runtime socket did not start")


def _wire_call(path: Path, payload: dict | None = None, *, raw: bytes | None = None) -> dict:
    wire = raw if raw is not None else json.dumps(payload, ensure_ascii=False).encode() + b"\n"
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(2)
        client.connect(str(path))
        client.sendall(wire)
        chunks: list[bytes] = []
        received = b""
        while b"\n" not in received:
            chunk = client.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
            received = b"".join(chunks)
    line = received.split(b"\n", 1)[0]
    assert line, "runtime closed without a contract response"
    return json.loads(line)


@pytest.fixture
def validation_runtime():
    root = Path(tempfile.mkdtemp(prefix="rj-validation-", dir="/tmp"))
    path = root / "r.sock"
    provider = _RecordingRuntimeProvider()
    server = RuntimeServer(path, provider)
    thread = server.run_in_thread()
    _wait_for_socket(path)
    try:
        yield server, thread, provider, path
    finally:
        server.stop()
        thread.join(timeout=2)
        shutil.rmtree(root, ignore_errors=True)


@pytest.mark.parametrize(
    "bad_payload",
    [
        _payload(state=[]),
        _payload(
            candidates=[
                {"id": "same", "text": "甲"},
                {"id": "same", "text": "乙"},
            ]
        ),
        _payload(max_age_ms=-1),
        _payload(max_age_ms=math.nan),
        _payload(candidates=[{"id": "mail", "text": ["邮箱"]}]),
    ],
    ids=["state-array", "duplicate-id", "negative-age", "nan-age", "text-array"],
)
def test_runtime_rejects_malformed_decide_before_provider(validation_runtime, bad_payload):
    _server, _thread, provider, path = validation_runtime

    response = _wire_call(path, bad_payload)

    assert response["status"] == "error"
    assert response["error"] == "invalid_request"
    assert "details" not in response
    assert provider.calls == []


class _CharTokenizer:
    def encode(self, text: str, add_special_tokens: bool = False) -> list[int]:
        return [ord(char) for char in text]

    def decode(self, tokens: list[int], skip_special_tokens: bool = True) -> str:
        return "".join(chr(token) for token in tokens)


class _Decision:
    def __init__(self, options, index: int, probabilities):
        self.options = tuple(options)
        self.index = index
        self.probabilities = tuple(probabilities)


class _MockLocalDecider:
    def __init__(self, probabilities_factory):
        self.tokenizer = _CharTokenizer()
        self.probabilities_factory = probabilities_factory
        self.calls: list[tuple[str, tuple[str, ...], int]] = []

    def decide(self, state, question, *, max_state_tokens):
        options = tuple(question.options)
        self.calls.append((state, options, max_state_tokens))
        return _Decision(options, 0, self.probabilities_factory(len(options)))


def _ready_local(decider: _MockLocalDecider) -> LocalProvider:
    provider = LocalProvider(
        "/offline/validation-model",
        loader=lambda _path: decider,
        warmup=False,
    )
    provider.start()
    assert provider.wait_until_ready(timeout=1)
    return provider


@pytest.mark.parametrize(
    "kind",
    ["non_numeric", "out_of_range", "zero_total", "incomplete"],
    ids=["non-numeric", "out-of-range", "zero-total", "incomplete"],
)
def test_local_provider_rejects_invalid_probability_contracts(kind):
    def probabilities(size: int):
        if kind == "non_numeric":
            return ("not-a-number",) + (0.0,) * (size - 1)
        if kind == "out_of_range":
            return (1.1,) + (0.0,) * (size - 1)
        if kind == "zero_total":
            return (0.0,) * size
        return (1.0,) * (size - 1)

    decider = _MockLocalDecider(probabilities)
    provider = _ready_local(decider)
    try:
        result = provider.decide(_request())
    finally:
        provider.shutdown()

    assert result.status == "error"
    assert result.error == "bad_response"
    assert "details" not in result.to_dict("validation-contract")


class _BrokenTokenizer:
    def encode(self, text: str, add_special_tokens: bool = False):
        return {"input_ids": {"unexpected": "tokenizer-data-secret"}}


class _BrokenTokenizerDecider:
    tokenizer = _BrokenTokenizer()
    calls = 0

    def decide(self, *args, **kwargs):
        self.calls += 1
        raise AssertionError("the model must not run after tokenizer validation fails")


def test_local_provider_hides_tokenizer_data_errors_behind_fixed_code():
    decider = _BrokenTokenizerDecider()
    provider = _ready_local(decider)  # type: ignore[arg-type]
    try:
        result = provider.decide(
            _request(context="tokenizer-data-secret should not appear in the response")
        )
    finally:
        provider.shutdown()

    encoded = json.dumps(result.to_dict("validation-contract"), ensure_ascii=False)
    assert result.status == "error"
    assert result.error == "bad_response"
    assert decider.calls == 0
    assert "tokenizer-data-secret" not in encoded


def test_local_provider_bounds_extreme_context_while_preserving_current_pinyin():
    decider = _MockLocalDecider(lambda size: (1.0,) + (0.0,) * (size - 1))
    provider = _ready_local(decider)
    old_marker = "old-context-secret-marker"
    context = old_marker + ("旧" * 20_000) + "最近的上下文"
    try:
        result = provider.decide(_request(context=context, pinyin="youxiang"))
    finally:
        provider.shutdown()

    assert result.status == "ready"
    assert decider.calls
    state, _options, max_state_tokens = decider.calls[0]
    assert "pinyin: youxiang" in state
    assert "最近的上下文" in state
    assert old_marker not in state
    assert max_state_tokens == MAX_STATE_TOKENS
    assert len(decider.tokenizer.encode(state)) <= MAX_STATE_TOKENS


class _MockTransport:
    def __init__(self, payload: dict, *, block: threading.Event | None = None):
        self.body = json.dumps(payload).encode("utf-8")
        self.block = block
        self.started = threading.Event()
        self.calls: list[dict[str, object]] = []
        self.closed = False

    def post(self, endpoint, *, body, headers, timeout):
        self.calls.append(
            {"endpoint": endpoint, "body": body, "headers": headers, "timeout": timeout}
        )
        if self.block is not None:
            self.started.set()
            self.block.wait(timeout=2)
        return HTTPResponse(status_code=200, headers={}, body=self.body)

    def close(self):
        self.closed = True


def _jev_payload(
    *, model: str = JEV_MODEL_ID, probabilities: dict[str, object] | None = None
) -> dict:
    return {
        "model": model,
        "answers": {
            "candidate": {
                "type": "choice",
                "choice": "0",
                "probabilities": probabilities
                if probabilities is not None
                else {"0": 1.0, "1": 0.0, "none": 0.0},
            }
        },
    }


def _jev_provider(transport) -> JevProvider:
    return JevProvider(
        "offline.validation.typesafe_key",
        secret_reader=lambda _ref: "mock-api-key",
        transport=transport,
        budget_path=None,
        input_token_estimator=lambda _body: 1,
    )


@pytest.mark.parametrize(
    "probabilities",
    [
        {"0": "not-a-number", "1": 0.0, "none": 0.0},
        {"0": 1.1, "1": 0.0, "none": 0.0},
        {"0": 0.0, "1": 0.0, "none": 0.0},
        {"0": 1.0, "1": 0.0},
    ],
    ids=["non-numeric", "out-of-range", "zero-total", "incomplete"],
)
def test_jev_provider_rejects_invalid_probability_contracts(probabilities):
    transport = _MockTransport(_jev_payload(probabilities=probabilities))
    provider = _jev_provider(transport)
    try:
        result = provider.decide(_request())
    finally:
        provider.shutdown()

    assert result.status == "error"
    assert result.error == "bad_response"
    assert "details" not in result.to_dict("validation-contract")


def test_jev_closed_provider_rejects_request_without_secret_or_transport_call():
    transport = _MockTransport(_jev_payload())
    secret_calls: list[str] = []
    provider = JevProvider(
        "offline.validation.typesafe_key",
        secret_reader=lambda ref: secret_calls.append(ref) or "mock-api-key",
        transport=transport,
        budget_path=None,
        input_token_estimator=lambda _body: 1,
    )
    provider.shutdown()

    result = provider.decide(_request())

    assert result.status == "unavailable"
    assert result.error == "runtime_closed"
    assert secret_calls == []
    assert transport.calls == []


def test_jev_provider_returns_busy_without_queueing_second_request():
    release = threading.Event()
    transport = _MockTransport(_jev_payload(), block=release)
    provider = _jev_provider(transport)
    first_results: list = []
    first = threading.Thread(target=lambda: first_results.append(provider.decide(_request())))
    first.start()
    assert transport.started.wait(timeout=1)

    try:
        second = provider.decide(_request())
    finally:
        release.set()
        first.join(timeout=2)
        provider.shutdown()

    assert second.status == "busy"
    assert second.error is None
    assert len(transport.calls) == 1
    assert first_results and first_results[0].status == "ready"


def test_jev_provider_rejects_response_with_wrong_model_id_as_fixed_bad_response():
    transport = _MockTransport(_jev_payload(model="unregistered-model"))
    provider = _jev_provider(transport)
    try:
        result = provider.decide(_request())
    finally:
        provider.shutdown()

    assert result.status == "error"
    assert result.error == "bad_response"
    assert "unregistered-model" not in json.dumps(result.to_dict("validation-contract"))


def test_jev_provider_rejects_oversized_request_body_without_transport_or_secret_call():
    marker = "oversized-request-body-secret"
    payload = _payload(
        candidates=[
            {
                "id": "huge",
                "text": marker + ("x" * (MAX_REQUEST_BODY_BYTES + 1)),
            }
        ]
    )
    request = DecisionRequest.from_payload(payload)
    transport = _MockTransport(_jev_payload())
    secret_calls: list[str] = []
    provider = JevProvider(
        "offline.validation.typesafe_key",
        secret_reader=lambda ref: secret_calls.append(ref) or "mock-api-key",
        transport=transport,
        budget_path=None,
        input_token_estimator=lambda _body: 1,
    )
    try:
        result = provider.decide(request)
    finally:
        provider.shutdown()

    assert result.status == "error"
    assert result.error == "invalid_request"
    assert transport.calls == []
    assert secret_calls == []
    assert marker not in json.dumps(result.to_dict(request.id), ensure_ascii=False)


class _OversizedHTTPResponse:
    status = 200
    headers = {}

    def __init__(self, body: bytes):
        self.body = body
        self.closed = False

    def read(self, size: int = -1) -> bytes:
        if size < 0:
            chunk, self.body = self.body, b""
        else:
            chunk, self.body = self.body[:size], self.body[size:]
        return chunk

    def close(self):
        self.closed = True


def test_jev_provider_maps_oversized_http_response_to_fixed_transport_error():
    marker = b"oversized-http-response-secret"
    response = _OversizedHTTPResponse(marker + (b"x" * (MAX_RESPONSE_BYTES + 1)))
    calls: list[object] = []

    def urlopen(*_args, **_kwargs):
        calls.append(True)
        return response

    transport = JevHTTPTransport(urlopen=urlopen, max_response_bytes=MAX_RESPONSE_BYTES)
    provider = _jev_provider(transport)
    try:
        result = provider.decide(_request())
    finally:
        provider.shutdown()

    assert result.status == "error"
    assert result.error == "transport_error"
    assert calls == [True]
    assert response.closed
    assert marker.decode() not in json.dumps(result.to_dict("validation-contract"))


def test_runtime_refuses_second_instance_while_active_socket_is_listening():
    root = Path(tempfile.mkdtemp(prefix="rj-active-", dir="/tmp"))
    path = root / "r.sock"
    first_provider = _RecordingRuntimeProvider()
    second_provider = _RecordingRuntimeProvider()
    first_server = RuntimeServer(path, first_provider)
    first_thread = first_server.run_in_thread()
    _wait_for_socket(path)
    second_server = RuntimeServer(path, second_provider)

    try:
        with pytest.raises(RuntimeError, match="already running"):
            second_server.start()
        assert first_server.is_running
        assert first_provider.started
        assert not second_provider.started
    finally:
        second_server.stop()
        first_server.stop()
        first_thread.join(timeout=2)
        shutil.rmtree(root, ignore_errors=True)


def test_runtime_oversized_wire_body_returns_message_too_large_without_payload():
    root = Path(tempfile.mkdtemp(prefix="rj-wire-", dir="/tmp"))
    path = root / "r.sock"
    provider = _RecordingRuntimeProvider()
    server = RuntimeServer(path, provider)
    thread = server.run_in_thread()
    _wait_for_socket(path)
    marker = b"oversized-wire-secret"
    raw = b'{"id":"' + marker + b'","payload":"' + b"x" * (MAX_MESSAGE_BYTES + 1) + b'"}\n'

    try:
        response = _wire_call(path, raw=raw)
    finally:
        server.stop()
        thread.join(timeout=2)
        shutil.rmtree(root, ignore_errors=True)

    assert response["status"] == "error"
    assert response["error"] == "message_too_large"
    assert marker.decode() not in json.dumps(response)
    assert provider.calls == []
