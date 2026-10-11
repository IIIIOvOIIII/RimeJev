from __future__ import annotations

import io
import json
import os
import subprocess
import sys
import traceback
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from rime_jev import runtime  # noqa: E402
from rime_jev.credentials import (  # noqa: E402
    MAX_API_KEY_BYTES,
    MAX_CREDENTIAL_BYTES,
    read_credential_stdin,
)
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


def test_stdin_credential_is_captured_from_utf8_json():
    key = "synthetic-密钥"
    stream = io.BytesIO(json.dumps({"api_key": key}, ensure_ascii=False).encode())
    assert read_credential_stdin(stream) == key
    assert stream.read() == b""


def test_credential_reader_accepts_a_real_pipe_written_once_then_closed():
    read_fd, write_fd = os.pipe()
    with os.fdopen(read_fd, "rb") as stream, os.fdopen(write_fd, "wb") as writer:
        writer.write(b'{"api_key":"synthetic-pipe-key"}')
        writer.close()
        assert read_credential_stdin(stream) == "synthetic-pipe-key"


@pytest.mark.parametrize("body", [
    b"", b" ", b"private-marker", b'{"api_key":"private-marker"', b"\xff",
    b"null", b"[]", b'"private-marker"', b"{}", b'{"api_key":null}',
    b'{"api_key":true}', b'{"api_key":123}', b'{"api_key":[]}',
    b'{"api_key":""}', b'{"api_key":"   "}', b'{"api_key":" key"}',
    b'{"api_key":"key\\nvalue"}', b'{"api_key":"key\\u0000value"}',
    b'{"api_key":"key\\u007fvalue"}', b'{"api_key":"\\ud800"}',
    b'{"api_key":"first","api_key":"second"}',
    b'{"api_key":"private-marker","extra":true}',
    b'{"api_key":"private-marker"}\n{"api_key":"second"}',
    b'{"api_key":"' + b"x" * MAX_CREDENTIAL_BYTES + b'"}',
    b"[" * 1500 + b"]" * 1500,
])
def test_invalid_stdin_credentials_are_redacted(body, capsys):
    with pytest.raises(CredentialUnavailable) as caught:
        read_credential_stdin(io.BytesIO(body))
    assert str(caught.value) == "credential_unavailable"
    assert "private-marker" not in "".join(traceback.format_exception(caught.value))
    assert caught.value.__suppress_context__
    assert capsys.readouterr() == ("", "")


def test_stdin_size_limit_includes_json_framing_and_handles_short_reads():
    class ShortReads(io.BytesIO):
        def read(self, size=-1):
            assert 0 < size <= MAX_CREDENTIAL_BYTES + 1
            return super().read(min(size, 7))

    key = '"' * MAX_API_KEY_BYTES
    body = json.dumps({"api_key": key}, separators=(",", ":")).encode()
    body += b" " * (MAX_CREDENTIAL_BYTES - len(body))
    assert len(body) == MAX_CREDENTIAL_BYTES
    assert read_credential_stdin(ShortReads(body)) == key
    stream = ShortReads(body + b" " * 1000)
    with pytest.raises(CredentialUnavailable):
        read_credential_stdin(stream)
    assert stream.tell() == MAX_CREDENTIAL_BYTES + 1


@pytest.mark.parametrize("unit", ["x", "é", "🧪", '"', "\\", "/"])
def test_stdin_key_size_limit_matches_swift_utf8_bytes(unit):
    assert MAX_API_KEY_BYTES == 2_000
    key = unit * (MAX_API_KEY_BYTES // len(unit.encode("utf-8")))
    assert len(key.encode("utf-8")) == MAX_API_KEY_BYTES
    body = json.dumps({"api_key": key}, ensure_ascii=False).encode()
    assert len(body) < MAX_CREDENTIAL_BYTES
    assert read_credential_stdin(io.BytesIO(body)) == key

    oversized = json.dumps({"api_key": key + "x"}, ensure_ascii=False).encode()
    assert len(oversized) < MAX_CREDENTIAL_BYTES
    with pytest.raises(CredentialUnavailable) as caught:
        read_credential_stdin(io.BytesIO(oversized))
    assert str(caught.value) == "credential_unavailable"


def test_stdin_limit_counts_utf8_bytes():
    body = json.dumps({"api_key": "界" * 2000}, ensure_ascii=False).encode()
    assert len(body.decode()) < MAX_CREDENTIAL_BYTES < len(body)
    with pytest.raises(CredentialUnavailable):
        read_credential_stdin(io.BytesIO(body))


@pytest.mark.parametrize("kind", ["read_error", "terminal", "closed", "text", "missing"])
def test_unavailable_stdin_fails_without_leaking_io_errors(kind):
    class BrokenPipe(io.BytesIO):
        def read(self, size=-1):
            raise OSError("private-marker")

    class Terminal(BrokenPipe):
        def isatty(self):
            return True

    closed = io.BytesIO()
    closed.close()
    stream = {"read_error": BrokenPipe(), "terminal": Terminal(), "closed": closed,
              "text": io.StringIO("private-marker"), "missing": None}[kind]
    with pytest.raises(CredentialUnavailable) as caught:
        read_credential_stdin(stream)
    assert "private-marker" not in "".join(traceback.format_exception(caught.value))


def _credential_argv(*extra):
    return ["--socket", "/unused/mock.sock", "--provider", "jev", *extra]


@pytest.mark.parametrize("metadata", [[], ["--vault-ref", "confirmed.typesafe_key"]])
def test_runtime_constructs_jev_with_captured_key_and_redacts_decision_data(monkeypatch, capsys, metadata):
    key = "synthetic-private-marker"
    body = json.dumps({"api_key": key}).encode()
    stream = io.BytesIO(body)
    monkeypatch.setattr(runtime.sys, "stdin", SimpleNamespace(buffer=stream))
    monkeypatch.setenv("TYPESAFE_API_KEY", "ignored-environment-key")
    monkeypatch.setattr(VaultSecretReader, "__init__", lambda *_a, **_k: pytest.fail("Vault constructed"))
    providers = []
    requests = []

    def urlopen(request, **_kwargs):
        requests.append(request)
        assert request.get_header("Authorization") == f"Bearer {key}"
        assert key.encode() not in request.data
        assert "api_key" not in json.loads(request.data)
        raise RuntimeError(key)

    def construct(source, *, secret_reader):
        assert source == "credential-stdin"
        assert secret_reader("ignored") == key
        stream.close()  # Subsequent provider reads must use the captured value.
        provider = JevProvider(source, secret_reader=secret_reader, urlopen=urlopen, budget_path=None)
        providers.append(provider)
        return provider

    class Server:
        def __init__(self, path, provider):
            assert path == "/unused/mock.sock"
            self.provider = provider

        def serve_forever(self):
            result = self.provider.decide(_request())
            assert result.error == "transport_error"
            assert key not in json.dumps(result.to_dict(_request().id))
            assert key not in json.dumps(self.provider.health().to_dict(None))

        def stop(self):
            self.provider.shutdown()

    monkeypatch.setattr(runtime, "JevProvider", construct)
    monkeypatch.setattr(runtime, "RuntimeServer", Server)
    assert runtime.main(_credential_argv("--credential-stdin", *metadata)) == 0
    assert len(providers) == len(requests) == 1
    assert capsys.readouterr() == ("", "")


@pytest.mark.parametrize("body", [b"", b"private-marker", b"x" * (MAX_CREDENTIAL_BYTES + 1)])
@pytest.mark.parametrize("metadata", [[], ["--vault-ref", "confirmed.typesafe_key"]])
def test_runtime_invalid_pipe_fails_before_provider_without_fallback(monkeypatch, capsys, body, metadata):
    monkeypatch.setattr(runtime.sys, "stdin", SimpleNamespace(buffer=io.BytesIO(body)))
    monkeypatch.setenv("TYPESAFE_API_KEY", "ignored-environment-key")
    monkeypatch.setattr(runtime, "JevProvider", lambda *_a, **_k: pytest.fail("Provider constructed"))
    monkeypatch.setattr(runtime, "RuntimeServer", lambda *_a, **_k: pytest.fail("Server constructed"))
    assert runtime.main(_credential_argv("--credential-stdin", *metadata)) == 1
    assert capsys.readouterr() == ("", "credential_unavailable\n")


@pytest.mark.parametrize("body", [b"", b"private-marker", b"x" * (MAX_CREDENTIAL_BYTES + 1)])
def test_cli_invalid_pipe_exits_with_only_safe_error(body, tmp_path):
    # Invalid input exits before any provider, model, Vault, or socket is opened.
    result = subprocess.run(
        [sys.executable, "-m", "rime_jev.runtime", "--provider", "jev",
         "--socket", str(tmp_path / "unused.sock"), "--credential-stdin"],
        input=body, capture_output=True, timeout=5,
        cwd=Path(__file__).resolve().parents[1] / "src",
    )
    assert result.returncode == 1
    assert result.stdout == b""
    assert result.stderr == b"credential_unavailable\n"
    assert not (tmp_path / "unused.sock").exists()


@pytest.mark.parametrize("provider", ["local", "tev-0.8b", "tev-4b"])
def test_stdin_flag_is_only_available_for_jev(monkeypatch, capsys, provider):
    monkeypatch.setattr(runtime, "read_credential_stdin", lambda *_a: pytest.fail("stdin read"))
    with pytest.raises(SystemExit) as caught:
        runtime.main(["--socket", "/unused/mock.sock", "--provider", provider, "--credential-stdin"])
    assert caught.value.code == 2
    assert "only supported for --provider jev" in capsys.readouterr().err


def test_legacy_vault_runtime_constructor_and_stdin_behavior_are_unchanged(monkeypatch):
    calls = []
    monkeypatch.setattr(runtime, "read_credential_stdin", lambda *_a: pytest.fail("stdin read"))

    def construct(*args, **kwargs):
        calls.append((args, kwargs))
        return object()

    class Server:
        def __init__(self, path, provider):
            pass

        def serve_forever(self):
            pass

        def stop(self):
            pass

    monkeypatch.setattr(runtime, "JevProvider", construct)
    monkeypatch.setattr(runtime, "RuntimeServer", Server)
    assert runtime.main(_credential_argv("--vault-ref", "confirmed.typesafe_key")) == 0
    assert calls == [(("confirmed.typesafe_key",), {})]
