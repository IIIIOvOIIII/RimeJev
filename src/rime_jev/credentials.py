"""One-shot, bounded credential input for the native Jev launcher."""

from __future__ import annotations

import json
from typing import BinaryIO

from .providers import CredentialUnavailable

MAX_CREDENTIAL_BYTES = 4 * 1024
# Matches JevKeychain.maxAPIKeyBytes, allowing for native JSON escaping.
MAX_API_KEY_BYTES = 2_000


def _unique_fields(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for name, value in pairs:
        if name in result:
            raise CredentialUnavailable("credential_unavailable")
        result[name] = value
    return result


def read_credential_stdin(stream: BinaryIO) -> str:
    """Read UTF-8 JSON through EOF; the launcher must write once and close its pipe.

    The entire payload, including JSON framing, is limited to 4 KiB. Only one
    extra byte is read to detect overflow. Errors never include input or causes.
    """
    try:
        if stream.isatty():
            raise ValueError
        body = bytearray()
        while len(body) <= MAX_CREDENTIAL_BYTES:
            chunk = stream.read(MAX_CREDENTIAL_BYTES + 1 - len(body))
            if not isinstance(chunk, bytes):
                raise ValueError
            if not chunk:
                break
            body.extend(chunk)
        if not body or len(body) > MAX_CREDENTIAL_BYTES:
            raise ValueError
        payload = json.loads(body.decode("utf-8"), object_pairs_hook=_unique_fields)
        if not isinstance(payload, dict) or set(payload) != {"api_key"}:
            raise ValueError
        value = payload["api_key"]
        if (
            not isinstance(value, str)
            or not value
            or value != value.strip()
            or any(ord(char) < 32 or ord(char) == 127 for char in value)
        ):
            raise ValueError
        # Encoding also rejects JSON escapes containing unpaired surrogates.
        if len(value.encode("utf-8")) > MAX_API_KEY_BYTES:
            raise ValueError
        return value
    except Exception:
        raise CredentialUnavailable("credential_unavailable") from None
