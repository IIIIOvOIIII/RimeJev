from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from rime_jev.http_transport import HTTPTransportError, JevHTTPTransport  # noqa: E402
import rime_jev.http_transport as http_transport  # noqa: E402


class FakeURLResponse:
    def __init__(self, body: bytes, *, status: int = 200, headers=None):
        self._body = body
        self.status = status
        self.headers = headers or {}
        self.closed = False

    def read(self, size=-1):
        body, self._body = self._body[:size], self._body[size:]
        return body

    def close(self):
        self.closed = True


class FakeSessionResponse:
    def __init__(self, body: bytes, *, status_code: int = 200, headers=None):
        self.content = body
        self.status_code = status_code
        self.headers = headers or {}


class FakeSession:
    def __init__(self):
        self.calls = []
        self.closed = False

    def post(self, endpoint, **kwargs):
        self.calls.append((endpoint, kwargs))
        return FakeSessionResponse(json.dumps({"ok": True}).encode())

    def close(self):
        self.closed = True


def test_requests_session_is_reused_and_tls_redirects_are_disabled():
    session = FakeSession()
    transport = JevHTTPTransport(session=session)

    first = transport.post(
        "https://api.example.test/v1/systemone",
        body=b"{}",
        headers={"Authorization": "Bearer secret"},
        timeout=1.0,
    )
    second = transport.post(
        "https://api.example.test/v1/systemone",
        body=b"{}",
        headers={"Authorization": "Bearer secret"},
        timeout=1.0,
    )

    assert first.status_code == second.status_code == 200
    assert len(session.calls) == 2
    assert session.calls[0][0] == session.calls[1][0]
    assert session.calls[0][1]["allow_redirects"] is False
    assert session.calls[0][1]["verify"] is True
    transport.close()
    assert session.closed


def test_default_transport_constructs_one_requests_session(monkeypatch):
    sessions = []

    def factory():
        session = FakeSession()
        sessions.append(session)
        return session

    monkeypatch.setattr(http_transport.requests, "Session", factory)
    transport = JevHTTPTransport()
    transport.post(
        "https://api.example.test/v1/systemone",
        body=b"{}",
        headers={},
        timeout=1.0,
    )
    transport.post(
        "https://api.example.test/v1/systemone",
        body=b"{}",
        headers={},
        timeout=1.0,
    )
    assert len(sessions) == 1
    assert len(sessions[0].calls) == 2
    transport.close()


def test_urlopen_injection_keeps_verified_context_and_maps_headers():
    seen = {}

    def urlopen(request, *, timeout, context):
        seen["request"] = request
        seen["timeout"] = timeout
        seen["context"] = context
        return FakeURLResponse(b'{"ok":true}', headers={"Retry-After": "9"})

    transport = JevHTTPTransport(urlopen=urlopen, ssl_context=object())
    response = transport.post(
        "https://api.example.test/v1/systemone",
        body=b"{}",
        headers={"Content-Type": "application/json"},
        timeout=2.0,
    )

    assert response.status_code == 200
    assert response.headers == {"Retry-After": "9"}
    assert seen["request"].full_url == "https://api.example.test/v1/systemone"
    assert seen["timeout"] == 2.0
    assert seen["context"] is not None


def test_urlopen_http_error_does_not_expose_response_body():
    import urllib.error

    def urlopen(*args, **kwargs):
        raise urllib.error.HTTPError(
            "https://api.example.test/v1/systemone",
            429,
            "too many requests",
            {"Retry-After": "12"},
            None,
        )

    transport = JevHTTPTransport(urlopen=urlopen)
    with pytest.raises(HTTPTransportError) as exc_info:
        transport.post(
            "https://api.example.test/v1/systemone",
            body=b'{"context":"private"}',
            headers={"Authorization": "Bearer secret"},
            timeout=1.0,
        )
    assert exc_info.value.status_code == 429
    assert exc_info.value.headers["Retry-After"] == "12"
    assert "private" not in str(exc_info.value)
    assert "secret" not in str(exc_info.value)


def test_transport_rejects_non_https_endpoint():
    transport = JevHTTPTransport(session=FakeSession())
    with pytest.raises(ValueError):
        transport.post(
            "http://api.example.test/v1/systemone",
            body=b"{}",
            headers={},
            timeout=1.0,
        )
