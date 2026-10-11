from __future__ import annotations

import json
import threading
import time
from dataclasses import replace

import pytest
import requests

from rime_jev import tev_provider as tev
from rime_jev.providers import Candidate, DecisionRequest, _decision_instruction
from rime_jev.tev_models import TEV_MODELS


def decision(**changes):
    return replace(DecisionRequest(
        "request-1", "请查看", "baogao",
        (Candidate("cid-7", "报告"), Candidate("cid-19", "宝高")), max_age_ms=1000,
    ), **changes)


def answer(body, choice=None):
    labels = tuple(body["questions"]["candidate"]["criteria"])
    choice = choice or labels[0]
    return {"model": body["model"], "answers": {"candidate": {
        "type": "choice", "choice": choice,
        "probabilities": {label: float(label == choice) for label in labels},
        "confidence": 0.999,
    }}}


class Response:
    def __init__(self, payload=None, *, raw=None, status=200, headers=None):
        self.raw = raw if raw is not None else json.dumps(payload).encode()
        self.status_code = status
        self.headers = headers or {}
        self.closed = False

    def iter_content(self, chunk_size):
        for offset in range(0, len(self.raw), chunk_size):
            yield self.raw[offset:offset + chunk_size]

    def close(self):
        self.closed = True


class Session:
    def __init__(self):
        self.trust_env = True
        self.calls = []
        self.responses = []
        self.callback = None
        self.closed = False
        self.close_event = threading.Event()

    def request(self, method, url, **kwargs):
        assert not self.trust_env
        assert url.startswith(tev.DEFAULT_BASE_URL + "/")
        assert kwargs["allow_redirects"] is False
        assert kwargs["stream"] is True
        assert 0 < kwargs["timeout"] <= tev.STARTUP_TIMEOUT_SECONDS
        body = json.loads(kwargs["data"]) if kwargs["data"] is not None else None
        self.calls.append((method, url, body, kwargs))
        result = self.callback(method, url, body, kwargs) if self.callback else None
        if result is None:
            if url.endswith("/api/tags"):
                result = Response({"models": [{"name": m["tag"], "digest": m["digest"]} for m in TEV_MODELS.values()]})
            elif url.endswith("/v1/systemone"):
                result = Response(answer(body))
            else:
                assert url.endswith("/api/generate")
                result = Response({"done": True, "model": body["model"]})
        self.responses.append(result)
        return result

    def close(self):
        self.closed = True
        self.close_event.set()

    @property
    def unloads(self):
        return [call[2] for call in self.calls if call[1].endswith("/api/generate")]


@pytest.fixture(autouse=True)
def forbid_live_calls(monkeypatch):
    def forbidden(*args, **kwargs):
        raise AssertionError("Tests must inject transport and runtime manager")
    monkeypatch.setattr(requests.Session, "request", forbidden)
    monkeypatch.setattr(tev, "ensure_tev_server", forbidden)


@pytest.fixture
def make_provider():
    providers = []

    def make(provider_id="tev-0.8b", *, start=True, session=None, **kwargs):
        session = session or Session()
        kwargs.setdefault("server_manager", lambda: tev.DEFAULT_BASE_URL)
        provider = tev.TevProvider(provider_id, session=session, **kwargs)
        providers.append(provider)
        if start:
            provider.start()
            assert provider.wait_until_ready(1), provider.health()
        return provider, session

    yield make
    for provider in providers:
        provider.shutdown()


@pytest.mark.parametrize("provider_id,tag,digest", [
    ("tev-0.8b", "tev1:0.8b", "d6e7bb9bfe0feda2548249c5fe9dde6113cf62d4a7eb0f95f5612573c2f2146e"),
    ("tev-4b", "tev1:4b", "4d24c6f6d61a48d9b72902f4805c5f1da53010736b834b0372377fb4bb7e53d3"),
])
def test_exact_identity_startup_warmup_and_decision(make_provider, provider_id, tag, digest):
    assert TEV_MODELS[provider_id]["digest"] == digest
    provider, session = make_provider(provider_id)
    assert provider.health().status == "ready"
    assert provider.health().provider == provider_id
    assert provider.model == provider.model_name == provider.health().model == tag
    assert [call[1].split(tev.DEFAULT_BASE_URL)[1] for call in session.calls] == ["/api/tags", "/v1/systemone"]
    warmup = session.calls[-1][2]
    assert warmup["model"] == tag and warmup["state"] == {"context": "", "pinyin": ""}
    result = provider.decide(decision())
    assert result.status == "ready" and result.provider == provider_id and result.model == tag
    assert result.choice_id == "cid-7"
    assert result.probabilities == {"cid-7": 1.0, "cid-19": 0.0, "none": 0.0}
    assert session.calls[-1][2]["model"] == tag
    assert session.calls[-1][2]["keep_alive"] == "10m"
    assert all(response.closed for response in session.responses)


def test_no_network_or_manager_before_explicit_start(make_provider):
    calls = []
    provider, session = make_provider(start=False, server_manager=lambda: calls.append(True))
    assert provider.health().status == "unavailable"
    assert provider.decide(decision()).error == "model_unavailable"
    assert not provider.wait_until_ready(0)
    provider.shutdown()
    provider.shutdown()
    provider.start()
    assert provider.decide(decision()).error == "runtime_closed"
    assert calls == session.calls == []
    assert session.closed


@pytest.mark.parametrize("url", [
    "http://example.com:11435", "http://localhost:11435", "http://127.0.0.1:11434",
    "http://127.0.0.1:11435/", "http://user:pass@127.0.0.1:11435",
    "http://127.0.0.1:11435?target=remote", "http://127.0.0.1:11435#remote",
    "https://127.0.0.1:11435", "http://127.0.0.2:11435", "http://[::1]:11435",
    "http://127.0.0.1:11435\n", None,
])
def test_url_guard_precedes_session_and_manager(monkeypatch, url):
    monkeypatch.setattr(requests, "Session", lambda: pytest.fail("Session created before URL validation"))
    with pytest.raises(ValueError, match="fixed numeric loopback"):
        tev.TevProvider("tev-0.8b", base_url=url)


def test_default_session_ignores_proxy_environment(monkeypatch):
    session = Session()
    monkeypatch.setenv("HTTP_PROXY", "http://proxy.example.invalid")
    monkeypatch.setenv("OLLAMA_HOST", "https://remote.example.invalid")
    monkeypatch.setattr(requests, "Session", lambda: session)
    provider = tev.TevProvider("tev-4b")
    assert not session.trust_env and session.calls == []
    provider.shutdown()


def test_unknown_provider_rejected_before_transport():
    with pytest.raises(ValueError, match="Unsupported Tev provider"):
        tev.TevProvider("tev1:latest")


def test_model_identity_is_copied_at_configuration(make_provider, monkeypatch):
    provider, session = make_provider(start=False)
    monkeypatch.setitem(TEV_MODELS["tev-0.8b"], "tag", "tev1:foreign")
    assert provider.health().model == "tev1:0.8b" and not session.calls


def test_startup_is_async_loading_rejects_inference_and_duplicate_start(make_provider):
    entered, release = threading.Event(), threading.Event()

    def manager():
        entered.set()
        assert release.wait(1)
        return tev.DEFAULT_BASE_URL

    provider, session = make_provider(start=False, server_manager=manager)
    try:
        provider.start()
        assert entered.wait(1)
        provider.start()
        assert provider.health().status == provider.decide(decision()).status == "loading"
        assert not session.calls
    finally:
        release.set()
    assert provider.wait_until_ready(1)
    assert len(session.calls) == 2


@pytest.mark.parametrize("listing,error", [
    ({"models": []}, "model_unavailable"),
    ({"models": [{"name": "tev1:0.8b", "digest": "foreign"}]}, "model_unavailable"),
    ({"models": [{"name": "tev1:4b", "digest": TEV_MODELS["tev-0.8b"]["digest"]}]}, "model_unavailable"),
    ({"models": [{"name": "tev1:0.8b", "digest": TEV_MODELS["tev-0.8b"]["digest"]}] * 2}, "model_unavailable"),
    ({"models": None}, "bad_response"), ([], "bad_response"),
])
def test_startup_requires_exact_unique_installed_manifest(make_provider, listing, error):
    provider, session = make_provider(start=False)
    session.callback = lambda *args: Response(listing)
    provider.start()
    assert not provider.wait_until_ready(1)
    assert provider.health().error == provider.decide(decision()).error == error
    provider.shutdown()
    assert len(session.calls) == 1 and session.unloads == []


@pytest.mark.parametrize("failure", ["remote", "exception", "timeout"])
def test_startup_manager_guard_and_deadline(make_provider, failure, capsys):
    now = [0.0]

    def manager():
        if failure == "exception":
            raise RuntimeError("private manager error")
        if failure == "timeout":
            now[0] = 61.0
        return "http://remote.invalid:11435" if failure == "remote" else tev.DEFAULT_BASE_URL

    provider, session = make_provider(start=False, server_manager=manager, clock=lambda: now[0])
    provider.start()
    assert not provider.wait_until_ready(1)
    assert provider.health().error == ("timeout" if failure == "timeout" else "model_load_failed")
    assert not session.calls
    assert "private" not in str(provider.health().to_dict("health"))
    assert capsys.readouterr() == ("", "")


def test_foreign_warmup_does_not_mark_ready(make_provider):
    provider, session = make_provider(start=False)

    def callback(method, url, body, kwargs):
        if url.endswith("/v1/systemone"):
            payload = answer(body)
            payload["model"] = "tev1:4b"
            return Response(payload)

    session.callback = callback
    provider.start()
    assert not provider.wait_until_ready(1)
    assert provider.health().error == "bad_response"
    provider.shutdown()
    assert session.unloads == [{"model": "tev1:0.8b", "keep_alive": 0, "stream": False}]


@pytest.mark.parametrize("abbreviated", [False, True])
def test_shared_instruction_and_short_full_completion(make_provider, abbreviated):
    provider, session = make_provider()
    request = decision(abbreviated=abbreviated)
    provider.decide(request)
    question = session.calls[-1][2]["questions"]["candidate"]
    assert question["type"] == "choice" and question["instructions"] == _decision_instruction(request)
    assert question["criteria"]["cid-7"] == "请查看报告"
    assert set(question["criteria"]) == {"cid-7", "cid-19", "none"}


@pytest.mark.parametrize("context,count", [("长" * 100, 2), ("c" * 256, 23), ("", 2)])
def test_long_or_repeated_context_uses_words_only(make_provider, context, count):
    provider, session = make_provider()
    request = decision(context=context, candidates=tuple(Candidate(f"cid-{i}", "报告") for i in range(count)))
    assert provider.decide(request).status == "ready"
    body = session.calls[-1][2]
    assert body["state"]["context"] == context
    assert body["questions"]["candidate"]["criteria"]["cid-0"] == "报告"


@pytest.mark.parametrize("input_request", [
    decision(candidates=tuple(Candidate(f"cid-{i}", "词") for i in range(24))),
    decision(candidates=(Candidate("none", "invalid"),)),
    decision(candidates=(Candidate("same", "one"), Candidate("same", "two"))),
    decision(context="x" * tev.MAX_REQUEST_BYTES),
    decision(max_age_ms=float("nan")), decision(max_age_ms=True), decision(max_age_ms=-1),
])
def test_invalid_input_never_reaches_transport(make_provider, input_request):
    provider, session = make_provider()
    before = len(session.calls)
    assert provider.decide(input_request).error == "invalid_request"
    assert len(session.calls) == before


def test_empty_candidates_and_zero_deadline_do_not_infer(make_provider):
    provider, session = make_provider()
    before = len(session.calls)
    assert provider.decide(decision(candidates=())).status == "no_match"
    assert provider.decide(decision(max_age_ms=0)).error == "timeout"
    assert len(session.calls) == before


def test_none_is_no_match_with_complete_probabilities(make_provider):
    provider, session = make_provider()
    session.callback = lambda method, url, body, kwargs: Response(answer(body, "none")) if url.endswith("/v1/systemone") else None
    result = provider.decide(decision())
    assert result.status == "no_match" and result.choice_id is None
    assert result.probabilities == {"cid-7": 0.0, "cid-19": 0.0, "none": 1.0}


@pytest.mark.parametrize("probabilities", [
    None, 0.99, [0.8, 0.1, 0.1], {"cid-7": 1.0},
    {"cid-7": 0.8, "foreign": 0.1, "none": 0.1},
    {"cid-7": True, "cid-19": 0, "none": 0},
    {"cid-7": "1", "cid-19": 0, "none": 0},
    {"cid-7": float("nan"), "cid-19": 0, "none": 0},
    {"cid-7": float("inf"), "cid-19": 0, "none": 0},
    {"cid-7": -0.1, "cid-19": 1.0, "none": 0.1},
    {"cid-7": 1.1, "cid-19": 0, "none": 0},
    {"cid-7": 0, "cid-19": 0, "none": 0},
    {"cid-7": 0.2, "cid-19": 0.2, "none": 0.2},
    {"cid-7": 0.1, "cid-19": 0.8, "none": 0.1},
])
def test_invalid_or_inconsistent_distribution_never_uses_scalar_confidence(make_provider, probabilities):
    provider, session = make_provider()

    def callback(method, url, body, kwargs):
        if url.endswith("/v1/systemone"):
            payload = answer(body)
            payload["answers"]["candidate"]["probabilities"] = probabilities
            return Response(payload)

    session.callback = callback
    assert provider.decide(decision()).error == "bad_response"
    session.callback = None
    assert provider.decide(decision()).choice_id == "cid-7"


@pytest.mark.parametrize("payload", [
    [], {}, {"model": "tev1:0.8b", "answers": None},
    {"model": "tev1:0.8b", "answers": {"candidate": {"type": "score", "choice": "cid-7"}}},
    {"model": "tev1:0.8b", "answers": {"candidate": {"type": "choice", "choice": "foreign"}}},
    {"model": "tev1:0.8b", "answers": {"candidate": {"type": "choice", "choice": "cid-7", "confidence": 1.0}}},
    {"model": "tev1:4b", "answers": {"candidate": {"type": "choice", "choice": "cid-7", "probabilities": {"cid-7": 1, "cid-19": 0, "none": 0}}}},
])
def test_foreign_model_malformed_answer_and_scalar_only_rejected(make_provider, payload):
    provider, session = make_provider()
    session.callback = lambda *args: Response(payload)
    assert provider.decide(decision()).error == "bad_response"


@pytest.mark.parametrize("status,error", [(301, "http_4xx"), (307, "http_4xx"), (401, "http_4xx"), (404, "http_4xx"), (500, "http_5xx")])
def test_http_failure_no_redirect_or_raw_error(make_provider, status, error, capsys):
    provider, session = make_provider()
    session.callback = lambda *args: Response(raw=b"private typed content", status=status, headers={"Location": "https://foreign.invalid"})
    result = provider.decide(decision())
    assert result.error == error and len(session.calls) == 3
    assert "private" not in str(result.to_dict("id"))
    assert session.responses[-1].closed and capsys.readouterr() == ("", "")


@pytest.mark.parametrize("response", [
    Response(raw=b"{invalid private payload"), Response(raw=b"\xff"),
    Response({}, headers={"Content-Length": str(tev.MAX_RESPONSE_BYTES + 1)}),
    Response({}, headers={"Content-Length": "-1"}), Response({}, headers={"Content-Length": "private invalid"}),
    Response(raw=b"x" * (tev.MAX_RESPONSE_BYTES + 1)),
])
def test_response_is_bounded_and_invalid_json_private(make_provider, response):
    provider, session = make_provider()
    session.callback = lambda *args: response
    result = provider.decide(decision())
    assert result.error == "bad_response" and response.closed
    assert "private" not in str(result.to_dict("id"))


@pytest.mark.parametrize("error,code", [
    (requests.Timeout("private"), "timeout"), (requests.ConnectionError("private"), "transport_error"),
    (TimeoutError("private"), "timeout"),
])
def test_transport_errors_are_fixed_codes(make_provider, error, code, capsys):
    provider, session = make_provider()

    def fail(*args):
        raise error

    session.callback = fail
    result = provider.decide(decision())
    assert result.error == code and "private" not in str(result.to_dict("id"))
    assert capsys.readouterr() == ("", "")


def test_timeout_stays_busy_until_inflight_finishes_late_reply_cannot_be_reused(make_provider):
    provider, session = make_provider()
    entered, release = threading.Event(), threading.Event()

    def blocked(method, url, body, kwargs):
        if url.endswith("/v1/systemone"):
            entered.set()
            assert release.wait(2)
            return Response(answer(body, "cid-19"))

    session.callback = blocked
    started = time.monotonic()
    result = provider.decide(decision(max_age_ms=30))
    try:
        assert entered.is_set() and result.error == "timeout"
        assert time.monotonic() - started < 0.5
        assert provider.health().status == provider.decide(decision()).status == "busy"
        assert len(session.calls) == 3 and not provider.unload_if_idle(now=10**10)
    finally:
        release.set()
    deadline = time.monotonic() + 1
    while provider.status == "busy" and time.monotonic() < deadline:
        time.sleep(0.001)
    session.callback = None
    assert provider.decide(decision(request_id="fresh")).choice_id == "cid-7"


def test_elapsed_budget_checked_even_when_worker_completes(make_provider):
    now = [0.0]
    provider, session = make_provider(clock=lambda: now[0])

    def late(method, url, body, kwargs):
        if url.endswith("/v1/systemone"):
            now[0] += 2
            return Response(answer(body))

    session.callback = late
    assert provider.decide(decision()).error == "timeout"


def test_idle_ten_minutes_unloads_only_selected_tag_once(make_provider):
    now = [10.0]
    provider, session = make_provider("tev-4b", clock=lambda: now[0])
    assert not provider.unload_if_idle(now=609.9)
    assert provider.health().status == "ready"
    assert provider.unload_if_idle(now=610.0)
    assert provider.status == "unloaded"
    assert provider.health().error == provider.decide(decision()).error == "unloaded"
    provider.shutdown()
    provider.shutdown()
    assert session.unloads == [{"model": "tev1:4b", "keep_alive": 0, "stream": False}]
    assert session.closed


def test_decision_refreshes_idle_clock_health_does_not(make_provider):
    now = [0.0]
    provider, session = make_provider(clock=lambda: now[0])
    now[0] = 590.0
    assert provider.decide(decision()).status == "ready"
    assert not provider.unload_if_idle(now=600.0)
    now[0] = 1190.0
    assert provider.health().status == "ready"
    assert provider.unload_if_idle()


def test_background_maintenance_releases_idle_model(make_provider):
    provider, session = make_provider(idle_seconds=0)
    deadline = time.monotonic() + 2
    while not session.unloads and time.monotonic() < deadline:
        time.sleep(0.01)
    assert session.unloads


@pytest.mark.parametrize("phase", ["manager", "warmup", "inference", "unload"])
def test_shutdown_during_work_defers_cleanup_and_discards_result(make_provider, phase):
    entered, release = threading.Event(), threading.Event()
    session = Session()

    def manager():
        if phase == "manager":
            entered.set()
            assert release.wait(2)
        return tev.DEFAULT_BASE_URL

    def callback(method, url, body, kwargs):
        should_block = phase == "warmup" and url.endswith("/v1/systemone")
        should_block |= phase == "inference" and url.endswith("/v1/systemone") and "cid-7" in body["questions"]["candidate"]["criteria"]
        should_block |= phase == "unload" and url.endswith("/api/generate")
        if should_block:
            entered.set()
            assert release.wait(2)

    session.callback = callback
    provider, session = make_provider(start=phase in {"inference", "unload"}, session=session, server_manager=manager)
    results = []
    worker = None
    shutdown_result = []
    stopper = threading.Thread(target=lambda: shutdown_result.append(provider.shutdown()))
    try:
        if phase in {"manager", "warmup"}:
            provider.start()
        else:
            def work():
                if phase == "inference":
                    results.append(provider.decide(decision()))
                else:
                    provider.unload_if_idle(now=10**10)
            worker = threading.Thread(target=work)
            worker.start()
        assert entered.wait(1)
        stopper.start()
        deadline = time.monotonic() + 1
        while provider.health().error != "runtime_closed" and time.monotonic() < deadline:
            time.sleep(0.001)
        assert provider.health().error == "runtime_closed" and not session.closed
        assert stopper.is_alive() and shutdown_result == []
    finally:
        release.set()
        if worker:
            worker.join(2)
        if stopper.ident is not None:
            stopper.join(2)
    assert session.close_event.wait(1)
    assert shutdown_result == [True]
    if phase == "manager":
        assert session.calls == []
    else:
        assert session.unloads == [{"model": "tev1:0.8b", "keep_alive": 0, "stream": False}]
    if results:
        assert results[0].error == "runtime_closed"


def test_shutdown_failure_private_does_not_touch_another_model(make_provider, capsys):
    provider, session = make_provider()
    session.callback = lambda *args: Response(raw=b"private error", status=500)
    assert provider.shutdown() is False
    assert provider.health().error == "runtime_closed"
    assert session.unloads == [{"model": "tev1:0.8b", "keep_alive": 0, "stream": False}]
    assert not session.closed and capsys.readouterr() == ("", "")
    assert provider.decide(decision()).error == "runtime_closed"
    session.callback = None
    assert provider.shutdown() is True
    assert session.closed and len(session.unloads) == 2
    assert provider.shutdown() is True and len(session.unloads) == 2


def test_switch_preserves_health_decision_and_unload_identities(make_provider):
    old, old_session = make_provider("tev-0.8b")
    old.shutdown()
    new, new_session = make_provider("tev-4b")
    assert old.health().model == "tev1:0.8b" and old.health().error == "runtime_closed"
    assert new.health().model == new.decide(decision()).model == "tev1:4b"
    new.shutdown()
    assert {c[2]["model"] for c in old_session.calls if c[2]} == {"tev1:0.8b"}
    assert {c[2]["model"] for c in new_session.calls if c[2]} == {"tev1:4b"}


def test_shutdown_wait_is_bounded_and_later_call_observes_finished_cleanup(make_provider):
    entered, release = threading.Event(), threading.Event()

    def manager():
        entered.set()
        assert release.wait(2)
        return tev.DEFAULT_BASE_URL

    provider, session = make_provider(start=False, server_manager=manager)
    provider.start()
    assert entered.wait(1)
    try:
        started = time.monotonic()
        assert provider.shutdown(timeout=0.01) is False
        assert time.monotonic() - started < 0.5
        assert not session.closed
    finally:
        release.set()
    assert provider.shutdown(timeout=1) is True
    assert session.closed and session.calls == []


@pytest.mark.parametrize("payload", [
    {"done": True, "model": "tev1:4b"},
    {"done": False, "model": "tev1:0.8b"},
    {"done": True}, [],
])
def test_unload_requires_confirmation_for_selected_tag(make_provider, payload):
    provider, session = make_provider()
    session.callback = lambda *args: Response(payload)
    assert not provider.unload_if_idle(now=10**10)
    assert provider.status == "unavailable"
    assert provider.health().error == "model_unavailable"
    assert provider.shutdown() is False
    assert len(session.unloads) == 2 and not session.closed
    session.callback = None
    assert provider.shutdown() is True
    assert len(session.unloads) == 3 and session.closed


def test_concurrent_shutdowns_share_failed_attempt_and_retry_is_bounded(make_provider):
    provider, session = make_provider()
    entered, release = threading.Event(), threading.Event()

    def unload(method, url, body, kwargs):
        entered.set()
        assert release.wait(2)
        return Response(status=500)

    session.callback = unload
    results = []
    stopper = threading.Thread(target=lambda: results.append(provider.shutdown(timeout=1)))
    stopper.start()
    try:
        assert entered.wait(1)
        assert provider.shutdown(timeout=0.01) is False
        assert len(session.unloads) == 1 and not session.closed
    finally:
        release.set()
        stopper.join(2)
    assert results == [False] and not session.closed
    assert len(session.unloads) == 1
    session.callback = None
    assert provider.shutdown(timeout=1) is True
    assert len(session.unloads) == 2 and session.closed


def test_shutdown_during_failed_idle_unload_does_not_retry_automatically(make_provider):
    provider, session = make_provider()
    entered, release = threading.Event(), threading.Event()

    def unload(method, url, body, kwargs):
        entered.set()
        assert release.wait(2)
        return Response(status=500)

    session.callback = unload
    worker = threading.Thread(target=lambda: provider.unload_if_idle(now=10**10))
    worker.start()
    try:
        assert entered.wait(1)
        assert provider.shutdown(timeout=0.01) is False
    finally:
        release.set()
        worker.join(2)
    assert len(session.unloads) == 1 and not session.closed
    assert provider.health().error == "runtime_closed"
    session.callback = None
    assert provider.shutdown(timeout=1) is True
    assert len(session.unloads) == 2 and session.closed
