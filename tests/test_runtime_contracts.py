from __future__ import annotations

import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from rime_jev.providers import ProviderResult  # noqa: E402
from rime_jev.runtime import MAX_MESSAGE_BYTES, RuntimeServer  # noqa: E402


class ContractProvider:
    provider_name = "local"
    model_name = "contract-model"

    def __init__(self) -> None:
        self.started = threading.Event()
        self.closed = threading.Event()

    def start(self) -> None:
        self.started.set()

    def health(self) -> ProviderResult:
        return ProviderResult(
            status="unavailable" if self.closed.is_set() else "ready",
            provider=self.provider_name,
            model=self.model_name,
            error="runtime_closed" if self.closed.is_set() else None,
        )

    def decide(self, request) -> ProviderResult:
        return ProviderResult(
            status="ready",
            provider=self.provider_name,
            model=self.model_name,
            choice_id=request.candidates[0].id if request.candidates else None,
            probabilities={request.candidates[0].id: 1.0, "none": 0.0}
            if request.candidates
            else {"none": 1.0},
        )

    def shutdown(self) -> None:
        self.closed.set()


def _wait_for_socket(path: Path, process: subprocess.Popen | None = None) -> None:
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        if path.exists():
            try:
                _exchange(path, b'{"id":"ready","op":"health"}\n')
                return
            except (OSError, ValueError):
                pass
        if process is not None and process.poll() is not None:
            stdout, stderr = process.communicate()
            raise AssertionError(
                f"CLI exited before creating its socket: {process.returncode}; "
                f"stdout={stdout!r}, stderr={stderr!r}"
            )
        time.sleep(0.01)
    raise AssertionError("runtime socket did not start")


def _exchange(path: Path, raw: bytes, *, close_write: bool = False) -> bytes:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(3)
        client.connect(str(path))
        client.sendall(raw)
        if close_write:
            client.shutdown(socket.SHUT_WR)
        chunks: list[bytes] = []
        received = b""
        while b"\n" not in received:
            chunk = client.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
            received = b"".join(chunks)
        return received.split(b"\n", 1)[0]


def _json_exchange(path: Path, raw: bytes, *, close_write: bool = False) -> dict:
    line = _exchange(path, raw, close_write=close_write)
    assert line, "runtime closed the connection without a contract response"
    return json.loads(line)


@pytest.fixture
def running_contract_runtime():
    # Keep the AF_UNIX path short enough for macOS while still exercising a private parent.
    root = Path(tempfile.mkdtemp(prefix="rj-contract-", dir="/tmp"))
    parent = root / "private"
    parent.mkdir(mode=0o755)
    os.chmod(parent, 0o755)
    path = parent / "r.sock"
    provider = ContractProvider()
    server = RuntimeServer(path, provider)
    thread = server.run_in_thread()
    _wait_for_socket(path)
    try:
        yield server, thread, provider, path
    finally:
        server.stop()
        thread.join(timeout=2)
        shutil.rmtree(root, ignore_errors=True)


def test_invalid_and_half_json_return_fixed_errors_without_input_leak(
    running_contract_runtime,
):
    _server, _thread, _provider, path = running_contract_runtime
    marker = b"request-secret-marker"
    cases = (
        (b'{"id":"broken-' + marker + b'","op":\n', False),
        (b"\xff\xfe" + marker + b"\n", False),
        (b'{"id":"half-' + marker + b'","op":"health"', True),
    )

    for raw, close_write in cases:
        line = _exchange(path, raw, close_write=close_write)
        response = json.loads(line)
        assert response["status"] == "error"
        assert response["error"] == "invalid_json"
        assert marker not in line
        assert "details" not in response


def test_oversized_json_returns_fixed_error_without_payload_leak(running_contract_runtime):
    _server, _thread, _provider, path = running_contract_runtime
    marker = b"oversized-request-secret"
    raw = b'{"id":"' + marker + b'","payload":"' + b"x" * (MAX_MESSAGE_BYTES + 1) + b'"}\n'

    line = _exchange(path, raw)
    response = json.loads(line)

    assert response["status"] == "error"
    assert response["error"] == "message_too_large"
    assert marker not in line
    assert "details" not in response


def test_stale_socket_is_replaced_and_shutdown_makes_socket_unusable():
    root = Path(tempfile.mkdtemp(prefix="rj-stale-", dir="/tmp"))
    try:
        path = root / "r.sock"
        stale = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        stale.bind(str(path))
        stale.close()

        provider = ContractProvider()
        server = RuntimeServer(path, provider)
        thread = server.run_in_thread()
        _wait_for_socket(path)
        assert provider.started.wait(timeout=1)

        response = _json_exchange(path, b'{"id":"health","op":"health"}\n')
        assert response["status"] == "ready"

        server.stop()
        thread.join(timeout=2)
        assert not thread.is_alive()
        assert not path.exists()

        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            with pytest.raises((FileNotFoundError, ConnectionRefusedError)):
                client.connect(str(path))
    finally:
        server.stop() if "server" in locals() else None
        if "thread" in locals():
            thread.join(timeout=2)
        shutil.rmtree(root, ignore_errors=True)


def test_cli_starts_on_private_socket_and_exits_cleanly_on_sigterm():
    root = Path(tempfile.mkdtemp(prefix="rj-cli-", dir="/tmp"))
    process: subprocess.Popen | None = None
    try:
        path = root / "r.sock"
        missing_model = root / "model-do-not-download"
        env = os.environ.copy()
        source = str(Path(__file__).resolve().parents[1] / "src")
        env["PYTHONPATH"] = source + os.pathsep + env.get("PYTHONPATH", "")
        process = subprocess.Popen(
            [
                sys.executable,
                "-m",
                "rime_jev.runtime",
                "--socket",
                str(path),
                "--provider",
                "local",
                "--model-path",
                str(missing_model),
            ],
            cwd=str(Path(__file__).resolve().parents[1]),
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        _wait_for_socket(path, process)

        response = _json_exchange(path, b'{"id":"cli-health","op":"health"}\n')
        assert response["provider"] == "local"
        assert response["status"] in {"loading", "unavailable"}

        process.send_signal(signal.SIGTERM)
        stdout, stderr = process.communicate(timeout=4)
        assert process.returncode == 0, f"stdout={stdout!r}, stderr={stderr!r}"
        assert not path.exists()
    finally:
        if process is not None and process.poll() is None:
            process.kill()
            process.communicate(timeout=2)
        shutil.rmtree(root, ignore_errors=True)
