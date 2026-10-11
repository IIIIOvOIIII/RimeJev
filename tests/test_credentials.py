from __future__ import annotations

import json
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from rime_jev.providers import (  # noqa: E402
    Candidate,
    CredentialUnavailable,
    DecisionRequest,
    JevProvider,
    VaultSecretReader,
)


class BytesResponse:
    def __init__(self, body: bytes) -> None:
        self._body = body
        self.closed = False

    def read(self, size: int = -1) -> bytes:
        if size < 0:
            size = len(self._body)
        body, self._body = self._body[:size], self._body[size:]
        return body

    def close(self) -> None:
        self.closed = True


def _request() -> DecisionRequest:
    return DecisionRequest(
        request_id="credential-contract",
        context="当前上下文",
        pinyin="youxiang",
        candidates=(Candidate("mail", "邮箱"),),
        max_age_ms=500,
    )


def test_vault_reader_uses_mock_bootstrap_and_returns_only_the_confirmed_ref_value():
    calls: dict[str, object] = {}
    response = BytesResponse(
        json.dumps({"ref": "confirmed.typesafe_key", "value": "mock-api-key"}).encode()
    )

    def run(argv, **kwargs):
        calls["argv"] = argv
        calls["run_kwargs"] = kwargs
        return SimpleNamespace(stdout="mock-service-bearer\n")

    def urlopen(request, *, timeout, context):
        calls["url"] = request.full_url
        calls["headers"] = dict(request.header_items())
        calls["timeout"] = timeout
        calls["context"] = context
        return response

    ssl_context = object()
    reader = VaultSecretReader(
        vault_url="https://vault.test/",
        helper_path="/mock/issue-token",
        run=run,
        urlopen=urlopen,
        ssl_context=ssl_context,
    )

    assert reader.read("confirmed.typesafe_key") == "mock-api-key"
    assert calls["argv"] == ["/mock/issue-token"]
    assert calls["run_kwargs"] == {
        "check": True,
        "capture_output": True,
        "text": True,
        "timeout": 15,
    }
    assert calls["url"] == "https://vault.test/api/v1/secrets/confirmed.typesafe_key"
    assert calls["headers"]["Authorization"] == "Bearer mock-service-bearer"
    assert calls["headers"]["Accept"] == "application/json"
    assert calls["timeout"] == 10
    assert calls["context"] is ssl_context
    assert response.closed


def test_vault_bootstrap_failure_does_not_call_vault_or_leak_helper_error():
    marker = "bootstrap-private-marker"
    vault_calls: list[object] = []

    def run(_argv, **_kwargs):
        raise RuntimeError(marker)

    def urlopen(*_args, **_kwargs):
        vault_calls.append(True)
        raise AssertionError("Vault must not be called when token bootstrap fails")

    reader = VaultSecretReader(run=run, urlopen=urlopen)
    with pytest.raises(CredentialUnavailable) as caught:
        reader.read("confirmed.typesafe_key")

    assert not vault_calls
    assert marker not in str(caught.value)


@pytest.mark.parametrize("bad_ref", ["", "../other", "nested/ref", None])
def test_invalid_vault_ref_is_rejected_before_bootstrap(bad_ref):
    bootstrap_calls: list[object] = []

    def run(*_args, **_kwargs):
        bootstrap_calls.append(True)
        return SimpleNamespace(stdout="must-not-be-used")

    reader = VaultSecretReader(run=run, urlopen=lambda *a, **k: None)
    with pytest.raises(CredentialUnavailable):
        reader.read(bad_ref)
    assert not bootstrap_calls


@pytest.mark.parametrize(
    "payload",
    [
        {"ref": "other.ref", "value": "upstream-secret-marker"},
        {"ref": "confirmed.typesafe_key", "value": ""},
        {"ref": "confirmed.typesafe_key", "value": 123},
    ],
)
def test_vault_response_must_match_ref_and_nonempty_string_value(payload):
    response = BytesResponse(json.dumps(payload).encode())
    reader = VaultSecretReader(
        run=lambda *a, **k: SimpleNamespace(stdout="mock-service-bearer"),
        urlopen=lambda *a, **k: response,
    )

    with pytest.raises(CredentialUnavailable) as caught:
        reader.read("confirmed.typesafe_key")

    assert "upstream-secret-marker" not in str(caught.value)
    assert response.closed


def test_jev_credential_bootstrap_failure_does_not_fallback_to_environment_or_network(
    monkeypatch,
):
    monkeypatch.setenv("TYPESAFE_API_KEY", "environment-key-must-not-be-used")
    secret_calls: list[str] = []
    network_calls: list[object] = []

    def secret_reader(ref: str) -> str:
        secret_calls.append(ref)
        raise CredentialUnavailable

    def urlopen(*_args, **_kwargs):
        network_calls.append(True)
        raise AssertionError("Jev network must not run without a Vault credential")

    provider = JevProvider(
        "confirmed.typesafe_key",
        secret_reader=secret_reader,
        urlopen=urlopen,
    )
    result = provider.decide(_request())
    provider.shutdown()

    assert result.status == "unavailable"
    assert result.error == "credential_unavailable"
    assert secret_calls == ["confirmed.typesafe_key"]
    assert not network_calls
    assert provider.health().error == "runtime_closed"
    assert "environment-key-must-not-be-used" not in str(result.to_dict(_request().id))
