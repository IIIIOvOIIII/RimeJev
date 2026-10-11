from __future__ import annotations

import json
from dataclasses import replace

import pytest
import requests

from rime_jev import providers, tev_provider
from rime_jev.providers import DecisionRequest, JevProvider, LocalProvider, ProviderInputError
from rime_jev.tev_models import TEV_MODELS
from test_providers import FakeDecider, FakeDecision, FakeSession, request, wait_ready
from test_tev_provider import Response, Session, answer


@pytest.fixture(autouse=True)
def forbid_live_calls(monkeypatch):
    def forbidden(*args, **kwargs):
        pytest.fail("Empty-context tests must use fake models, credentials, and transports")

    monkeypatch.setattr(providers, "_load_local_decider", forbidden)
    monkeypatch.setattr(providers.VaultSecretReader, "__call__", forbidden)
    monkeypatch.setattr(providers.urllib.request, "urlopen", forbidden)
    monkeypatch.setattr(requests.Session, "request", forbidden)
    monkeypatch.setattr(tev_provider, "ensure_tev_server", forbidden)


@pytest.fixture(params=[False, True], ids=["full-pinyin", "abbreviated-pinyin"])
def empty_request(request):
    return DecisionRequest.from_payload({
        "id": "empty-context",
        "state": {"context": "", "pinyin": "yx" if request.param else "youxiang", "abbreviated": request.param},
        "candidates": [{"id": "mail", "text": "邮箱"}, {"id": "tank", "text": "油箱"}],
        "max_age_ms": 1000,
    })


def test_empty_context_validation_preserves_supplied_input(empty_request):
    assert empty_request.context == ""
    assert empty_request.pinyin == ("yx" if empty_request.abbreviated else "youxiang")
    assert [(candidate.id, candidate.text) for candidate in empty_request.candidates] == [
        ("mail", "邮箱"), ("tank", "油箱"),
    ]
    assert empty_request.max_age_ms == 1000


@pytest.mark.parametrize("state", [
    {"pinyin": "youxiang"},
    {"context": None, "pinyin": "youxiang"},
    {"context": 0, "pinyin": "youxiang"},
])
def test_missing_or_invalid_context_is_not_treated_as_empty(state):
    with pytest.raises(ProviderInputError):
        DecisionRequest.from_payload({"state": state, "candidates": [{"id": "mail", "text": "邮箱"}]})


def test_empty_context_instruction_is_explicit_and_allows_abstention(empty_request):
    instruction = providers._decision_instruction(empty_request)
    assert "state.context is empty: there is no preceding text" in instruction
    assert "using only the current pinyin and the candidates themselves" in instruction
    assert "passed Rime's pinyin matching, including abbreviated pinyin" in instruction
    assert "Do not invent preceding context, a situation, or the user's intent" in instruction
    assert "you may choose none" in instruction


@pytest.mark.parametrize("context", ["前文", " "])
@pytest.mark.parametrize("abbreviated", [False, True])
def test_nonempty_context_keeps_existing_instruction(context, abbreviated):
    req = replace(request(), context=context, abbreviated=abbreviated)
    expected = providers.ABBREVIATED_INSTRUCTION if abbreviated else providers.DECISION_INSTRUCTION
    assert providers._decision_instruction(req) == expected


@pytest.mark.parametrize("abstain", [False, True], ids=["candidate", "none"])
def test_tt_infers_with_empty_context_and_original_options(empty_request, abstain, monkeypatch):
    questions = []

    class CapturedQuestion:
        def __init__(self, instruction, options):
            self.instruction, self.options = instruction, tuple(options)
            questions.append(self)

    class Decider(FakeDecider):
        def decide(self, state, question, *, max_state_tokens):
            result = super().decide(state, question, max_state_tokens=max_state_tokens)
            assert max_state_tokens == providers.MAX_STATE_TOKENS
            if abstain:
                return FakeDecision(question.options, 2, (0.0, 0.0, 1.0))
            return result

    monkeypatch.setattr(providers, "Question", CapturedQuestion)
    decider = Decider()
    provider = LocalProvider("/offline/model", loader=lambda _: decider, warmup=False)
    try:
        provider.start()
        wait_ready(provider)
        result = provider.decide(empty_request)
    finally:
        provider.shutdown()

    assert result.model == providers.LOCAL_MODEL_ID
    assert result.status == ("no_match" if abstain else "ready")
    assert result.choice_id == (None if abstain else "mail")
    assert len(decider.calls) == len(questions) == 1
    state, options = decider.calls[0]
    assert state == "\npinyin: " + empty_request.pinyin
    assert questions[0].instruction == providers.EMPTY_CONTEXT_INSTRUCTION
    assert [json.loads(option.split(" ", 1)[1]) for option in options] == [
        {"id": "mail", "text": "邮箱"}, {"id": "tank", "text": "油箱"},
        {"id": "none", "text": "no candidate matches"},
    ]


@pytest.mark.parametrize("abstain", [False, True], ids=["candidate", "none"])
def test_jev_sends_empty_context_and_original_candidates(empty_request, abstain, tmp_path):
    choice = "none" if abstain else "0"
    session = FakeSession(json.dumps({
        "model": providers.JEV_MODEL_ID,
        "answers": {"candidate": {
            "type": "choice", "choice": choice,
            "probabilities": {label: float(label == choice) for label in ("0", "1", "none")},
        }},
    }).encode())
    provider = JevProvider(
        "test.ref", secret_reader=lambda _: "mock-api-key", session=session,
        budget_path=tmp_path / "budget.json",
    )
    try:
        result = provider.decide(empty_request)
    finally:
        provider.shutdown()

    assert result.model == providers.JEV_MODEL_ID
    assert result.status == ("no_match" if abstain else "ready")
    assert result.choice_id == (None if abstain else "mail")
    assert len(session.calls) == 1
    body = json.loads(session.calls[0]["data"])
    assert body["state"] == {"context": "", "pinyin": empty_request.pinyin}
    question = body["questions"]["candidate"]
    assert question["instructions"] == providers.EMPTY_CONTEXT_INSTRUCTION
    assert question["criteria"] == {
        "0": "id=mail; text=邮箱" + ("; continuation=邮箱" if empty_request.abbreviated else ""),
        "1": "id=tank; text=油箱" + ("; continuation=油箱" if empty_request.abbreviated else ""),
        "none": "The current pinyin and declared candidates do not support a choice.",
    }


@pytest.mark.parametrize("provider_id", ["tev-0.8b", "tev-4b"])
@pytest.mark.parametrize("abstain", [False, True], ids=["candidate", "none"])
def test_tev_sends_empty_context_and_shared_instruction(empty_request, abstain, provider_id):
    session = Session()
    provider = tev_provider.TevProvider(
        provider_id, session=session, server_manager=lambda: tev_provider.DEFAULT_BASE_URL,
    )
    try:
        provider.start()
        assert provider.wait_until_ready(1)
        session.calls.clear()
        session.callback = lambda method, url, body, kwargs: (
            Response(answer(body, "none" if abstain else "mail"))
            if url.endswith("/v1/systemone") else None
        )
        result = provider.decide(empty_request)
        assert len(session.calls) == 1
        body = session.calls[0][2]
    finally:
        provider.shutdown()

    assert result.model == body["model"] == TEV_MODELS[provider_id]["tag"]
    assert result.status == ("no_match" if abstain else "ready")
    assert result.choice_id == (None if abstain else "mail")
    assert body["state"] == {"context": "", "pinyin": empty_request.pinyin}
    question = body["questions"]["candidate"]
    assert question["instructions"] == providers.EMPTY_CONTEXT_INSTRUCTION
    assert set(question["criteria"]) == {"mail", "tank", "none"}
    assert question["criteria"]["mail"] == "邮箱"
    assert question["criteria"]["tank"] == "油箱"
