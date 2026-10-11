from __future__ import annotations

import json
import os
import socket
import stat
import sys
import threading
import time
import shutil
import tempfile
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from rime_jev.providers import Candidate, DecisionRequest, ProviderResult  # noqa: E402
from rime_jev.runtime import MAX_MESSAGE_BYTES, RuntimeServer  # noqa: E402


class FakeProvider:
    provider_name = "local"
    model_name = "fake-local-model"

    def __init__(self, *, block: threading.Event | None = None):
        self.block = block
        self.started = False
        self.closed = False
        self.decide_started = threading.Event()

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
        self.decide_started.set()
        if self.block is not None:
            self.block.wait(timeout=2)
        return ProviderResult(
            status="ready",
            provider=self.provider_name,
            model=self.model_name,
            choice_id=request.candidates[0].id if request.candidates else None,
            probabilities={request.candidates[0].id: 1.0, "none": 0.0}
            if request.candidates
            else {"none": 1.0},
        )

    def shutdown(self):
        self.closed = True


def payload(request_id="r1"):
    return {
        "id": request_id,
        "op": "decide",
        "state": {"context": "context", "pinyin": "youxiang"},
        "candidates": [{"id": "c1", "text": "邮箱"}],
        "max_age_ms": 1000,
    }


def wait_for_socket(path: Path):
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        if path.exists():
            try:
                call(path, {"id": "ready", "op": "health"})
                return
            except (OSError, ValueError):
                pass
        time.sleep(0.01)
    raise AssertionError("runtime socket did not start")


def call(path: Path, request: dict, *, raw: bytes | None = None) -> dict:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(2)
        client.connect(str(path))
        client.sendall(raw if raw is not None else json.dumps(request).encode() + b"\n")
        chunks = []
        while b"\n" not in b"".join(chunks):
            chunks.append(client.recv(65536))
            if not chunks[-1]:
                break
        return json.loads(b"".join(chunks).split(b"\n", 1)[0])


@pytest.fixture
def running_runtime():
    # macOS limits AF_UNIX paths to roughly 104 bytes; pytest's nested tmp_path is longer.
    root = Path(tempfile.mkdtemp(prefix="rj-", dir="/tmp"))
    parent = root / "private-runtime"
    parent.mkdir(mode=0o755)
    os.chmod(parent, 0o755)
    path = parent / "rime-jev.sock"
    provider = FakeProvider()
    server = RuntimeServer(path, provider)
    thread = server.run_in_thread()
    wait_for_socket(path)
    yield server, thread, provider, parent, path
    server.stop()
    thread.join(timeout=2)
    shutil.rmtree(root, ignore_errors=True)


def test_socket_parent_and_socket_are_private(running_runtime):
    server, thread, provider, parent, path = running_runtime
    assert stat.S_IMODE(parent.stat().st_mode) == 0o700
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert provider.started


def test_health_is_available_while_a_decision_is_blocked(running_runtime):
    server, thread, provider, parent, path = running_runtime
    release = threading.Event()
    provider.block = release

    decision_response: list[dict] = []
    decision_thread = threading.Thread(target=lambda: decision_response.append(call(path, payload())))
    decision_thread.start()
    assert provider.decide_started.wait(timeout=1)

    started = time.monotonic()
    health = call(path, {"id": "health", "op": "health"})
    assert time.monotonic() - started < 0.5
    assert health["status"] == "ready"
    release.set()
    decision_thread.join(timeout=2)
    assert decision_response and decision_response[0]["status"] == "ready"


def test_one_decide_request_gets_one_response_and_provider_is_fixed(running_runtime):
    server, thread, provider, parent, path = running_runtime
    request = payload("one")
    request["provider"] = "jev"
    response = call(path, request)
    assert response["id"] == "one"
    assert response["provider"] == "local"
    assert response["choice_id"] == "c1"
    assert response["probabilities"] == {"c1": 1.0, "none": 0.0}


def test_oversized_json_line_returns_fixed_error_without_payload(running_runtime):
    server, thread, provider, parent, path = running_runtime
    oversized = b"{" + b"x" * (MAX_MESSAGE_BYTES + 1) + b"}\n"
    response = call(path, {}, raw=oversized)
    assert response["status"] == "error"
    assert response["error"] == "message_too_large"
    assert "details" not in response


def test_shutdown_returns_before_closing_socket_and_removes_it(running_runtime):
    server, thread, provider, parent, path = running_runtime
    response = call(path, {"id": "bye", "op": "shutdown"})
    assert response["id"] == "bye"
    assert response["status"] == "ready"
    thread.join(timeout=2)
    assert not thread.is_alive()
    deadline = time.monotonic() + 1
    while path.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    assert not path.exists()
    assert provider.closed


def test_invalid_decide_is_a_fixed_code_without_request_payload(running_runtime):
    server, thread, provider, parent, path = running_runtime
    response = call(path, {"id": "bad", "op": "decide", "state": {}})
    assert response["status"] == "error"
    assert response["error"] == "invalid_request"
    assert "details" not in response
