"""Small HTTPS transport used by the Jev provider.

The production path owns one :class:`requests.Session`, which lets urllib3 keep
the HTTPS connection pool alive between Jev decisions.  Tests and offline
evaluation can still inject the existing ``urllib.request.urlopen`` callable;
that path keeps its request object, timeout and verified SSL context contract.
No transport code logs request headers or bodies.
"""

from __future__ import annotations

import socket
import ssl
import urllib.error
import urllib.request
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any, Callable

try:  # requests is a locked runtime dependency, but keep import errors explicit.
    import requests
except ImportError:  # pragma: no cover - exercised only by a broken installation.
    requests = None  # type: ignore[assignment]


MAX_RESPONSE_BYTES = 512 * 1024


@dataclass(frozen=True)
class HTTPResponse:
    """The bounded response data needed by the Jev adapter."""

    status_code: int
    headers: Mapping[str, str]
    body: bytes


class HTTPTransportError(OSError):
    """A transport-level HTTP failure with a safe status/header surface."""

    def __init__(self, status_code: int, headers: Mapping[str, str] | None = None) -> None:
        super().__init__(f"HTTP status {status_code}")
        self.status_code = int(status_code)
        self.headers = dict(headers or {})


def _normalise_headers(raw: Any) -> dict[str, str]:
    if raw is None:
        return {}
    try:
        items = raw.items()
    except AttributeError:
        return {}
    output: dict[str, str] = {}
    for key, value in items:
        output[str(key)] = str(value)
    return output


def _read_bounded(response: Any, limit: int) -> bytes:
    chunks: list[bytes] = []
    total = 0
    try:
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
    finally:
        close = getattr(response, "close", None)
        if callable(close):
            close()
    return b"".join(chunks)


class JevHTTPTransport:
    """Verified HTTPS POST transport with a reusable requests session.

    ``urlopen`` is deliberately checked before constructing a Session.  This
    preserves the old test seam and avoids silently changing injected/offline
    callers.  The requests path always leaves certificate verification enabled.
    """

    def __init__(
        self,
        *,
        session: Any | None = None,
        urlopen: Callable[..., Any] | None = None,
        ssl_context: ssl.SSLContext | None = None,
        max_response_bytes: int = MAX_RESPONSE_BYTES,
    ) -> None:
        if isinstance(max_response_bytes, bool) or int(max_response_bytes) <= 0:
            raise ValueError("max_response_bytes must be positive")
        self._urlopen = urlopen
        self._ssl_context = ssl_context
        self._max_response_bytes = int(max_response_bytes)
        self._closed = False
        self._session = None
        if urlopen is None:
            if session is not None:
                self._session = session
            elif requests is not None:
                self._session = requests.Session()
            else:  # pragma: no cover - dependency lock should prevent this path.
                raise RuntimeError("requests is unavailable")

    @property
    def session(self) -> Any | None:
        return self._session

    def post(
        self,
        endpoint: str,
        *,
        body: bytes,
        headers: Mapping[str, str],
        timeout: float,
    ) -> HTTPResponse:
        if self._closed:
            raise OSError("transport is closed")
        if not isinstance(endpoint, str) or not endpoint.startswith("https://"):
            raise ValueError("Jev endpoint must use HTTPS")
        if timeout <= 0:
            raise ValueError("timeout must be positive")

        if self._urlopen is not None:
            request = urllib.request.Request(
                endpoint,
                data=body,
                headers=dict(headers),
                method="POST",
            )
            try:
                response = self._urlopen(
                    request,
                    timeout=timeout,
                    context=self._ssl_context,
                )
            except urllib.error.HTTPError as exc:
                raise HTTPTransportError(
                    int(exc.code), _normalise_headers(getattr(exc, "headers", None))
                ) from exc
            status = getattr(response, "status", None)
            if not isinstance(status, int):
                status = getattr(response, "code", None)
            if not isinstance(status, int):
                status = 200
            return HTTPResponse(
                status_code=status,
                headers=_normalise_headers(getattr(response, "headers", None)),
                body=_read_bounded(response, self._max_response_bytes),
            )

        session = self._session
        if session is None:  # pragma: no cover - guarded during construction.
            raise RuntimeError("HTTPS session is unavailable")
        try:
            # Explicit True documents the TLS invariant and keeps tests able to
            # assert that no insecure verification override is used.
            response = session.post(
                endpoint,
                data=body,
                headers=dict(headers),
                timeout=timeout,
                allow_redirects=False,
                verify=True,
            )
        except Exception as exc:
            if requests is not None:
                if isinstance(exc, requests.exceptions.Timeout):
                    raise socket.timeout from exc
                if isinstance(exc, requests.exceptions.ConnectionError):
                    raise OSError from exc
            raise

        status = getattr(response, "status_code", 200)
        if isinstance(status, bool) or not isinstance(status, int):
            raise ValueError("invalid HTTP status")
        body_value = getattr(response, "content", b"")
        if not isinstance(body_value, bytes):
            body_value = bytes(body_value)
        if len(body_value) > self._max_response_bytes:
            raise ValueError("response too large")
        return HTTPResponse(
            status_code=status,
            headers=_normalise_headers(getattr(response, "headers", None)),
            body=body_value,
        )

    def close(self) -> None:
        self._closed = True
        close = getattr(self._session, "close", None)
        if callable(close):
            close()


__all__ = [
    "HTTPResponse",
    "HTTPTransportError",
    "JevHTTPTransport",
    "MAX_RESPONSE_BYTES",
]
