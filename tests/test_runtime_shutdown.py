from __future__ import annotations

import os
import runpy
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

import pytest

from rime_jev import runtime
from test_runtime import FakeProvider, call, payload, wait_for_socket


@pytest.mark.parametrize("failure", [False, RuntimeError("private shutdown failure")])
def test_concurrent_stop_failure_keeps_listener_and_can_retry(failure, monkeypatch):
    entered, release = threading.Event(), threading.Event()

    class Provider(FakeProvider):
        calls = 0

        def shutdown(self):
            self.calls += 1
            if self.calls == 1:
                # A callback on the shutdown worker must never wait on itself.
                assert server.stop() is False
                entered.set()
                assert release.wait(2)
                if isinstance(failure, Exception):
                    raise failure
                return failure
            return True

    with tempfile.TemporaryDirectory(prefix="rj-stop-", dir="/tmp") as directory:
        path = Path(directory) / "r.sock"
        provider = Provider()
        server = runtime.RuntimeServer(path, provider)
        serving = server.run_in_thread()
        results = []
        stopper = threading.Thread(target=lambda: results.append(server.stop()))
        concurrent = threading.Thread(target=lambda: results.append(server.stop()))
        try:
            wait_for_socket(path)
            stopper.start()
            assert entered.wait(1)
            concurrent.start()
            monkeypatch.setattr(runtime, "SHUTDOWN_WAIT_SECONDS", 0.01)
            assert server.stop() is False
            assert provider.calls == 1 and path.exists()
            assert call(path, {"op": "health"})["error"] == "runtime_closed"
            release.set()
            stopper.join(2)
            concurrent.join(2)
            assert results == [False, False]
            assert provider.calls == 1 and serving.is_alive()
            assert not server._shutdown_complete.is_set()
            assert call(path, payload())["error"] == "runtime_closed"
            monkeypatch.setattr(runtime, "SHUTDOWN_WAIT_SECONDS", 1)
            assert server.stop() is True
            serving.join(2)
            assert provider.calls == 2 and not path.exists() and not serving.is_alive()
        finally:
            release.set()
            if stopper.ident is not None:
                stopper.join(2)
            if concurrent.ident is not None:
                concurrent.join(2)
            server.stop()
            serving.join(2)


def test_unlink_failure_keeps_listener_owned_for_retry(monkeypatch):
    with tempfile.TemporaryDirectory(prefix="rj-unlink-", dir="/tmp") as directory:
        path = Path(directory) / "r.sock"
        server = runtime.RuntimeServer(path, FakeProvider())
        serving = server.run_in_thread()
        original = Path.unlink

        def fail_unlink(self, *args, **kwargs):
            if self == path:
                raise PermissionError("fixture")
            return original(self, *args, **kwargs)

        try:
            wait_for_socket(path)
            with monkeypatch.context() as patch:
                patch.setattr(Path, "unlink", fail_unlink)
                assert server.stop() is False
                assert path.exists() and serving.is_alive()
                assert call(path, {"op": "health"})["error"] == "runtime_closed"
            assert server.stop() is True
            serving.join(2)
            assert not path.exists() and not serving.is_alive()
        finally:
            server.stop()
            serving.join(2)


@pytest.mark.parametrize("trigger", ["signal", "socket"])
def test_repeated_sigterm_keeps_accept_loop_live_during_unload(trigger):
    # Exercise the real signal handlers with a fake provider and short temporary paths.
    source = """
import sys, time
from pathlib import Path
from rime_jev import runtime
from rime_jev.providers import ProviderResult
root = Path(sys.argv[1])
class Provider:
    provider_name = 'local'
    model_name = 'fixture'
    def __init__(self, *args): pass
    def start(self): pass
    def health(self): return ProviderResult(status='ready', provider='local', model='fixture')
    def shutdown(self):
        with (root / 'attempts').open('a') as output: output.write('stop\\n')
        deadline = time.monotonic() + 5
        while not (root / 'release').exists():
            if time.monotonic() >= deadline: return False
            time.sleep(.01)
        return True
runtime.LocalProvider = Provider
raise SystemExit(runtime.main(['--socket', str(root / 'r.sock'), '--provider', 'local', '--model-path', 'fixture']))
"""
    with tempfile.TemporaryDirectory(prefix="rj-signal-", dir="/tmp") as directory:
        root = Path(directory)
        path = root / "r.sock"
        env = os.environ.copy()
        env["PYTHONPATH"] = str(Path(__file__).resolve().parents[1] / "src")
        process = subprocess.Popen(
            [sys.executable, "-c", source, directory], env=env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        try:
            wait_for_socket(path)
            if trigger == "signal":
                process.send_signal(signal.SIGTERM)
            else:
                assert call(path, {"op": "shutdown"})["status"] == "ready"
            deadline = time.monotonic() + 1
            while not (root / "attempts").exists() and time.monotonic() < deadline:
                time.sleep(.01)
            assert (root / "attempts").exists()
            for _ in range(3):
                process.send_signal(signal.SIGTERM)
                assert call(path, {"op": "health"})["error"] == "runtime_closed"
            assert process.poll() is None and path.exists()
            assert (root / "attempts").read_text().splitlines() == ["stop"]
            (root / "release").touch()
            stdout, stderr = process.communicate(timeout=3)
            assert process.returncode == 0, (stdout, stderr)
            assert not path.exists()
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=2)


def test_stop_script_refused_socket_is_pending_until_removed():
    stop_runtimes = runpy.run_path(str(Path(__file__).resolve().parents[1] / "scripts/stop_runtime.py"))["stop_runtimes"]
    with tempfile.TemporaryDirectory(prefix="rj-script-", dir="/tmp") as directory:
        root = Path(directory)
        path = root / "tev-4b.sock"
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stale:
            stale.bind(str(path))
        with pytest.raises(SystemExit, match="has not finished shutdown"):
            stop_runtimes(root, timeout=.01)
        assert path.exists()
        removed = threading.Timer(.1, path.unlink)
        removed.start()
        try:
            stop_runtimes(root, timeout=1)
            assert not path.exists()
        finally:
            removed.join(2)


def test_stop_script_acknowledgement_does_not_complete_shutdown():
    stop_runtimes = runpy.run_path(str(Path(__file__).resolve().parents[1] / "scripts/stop_runtime.py"))["stop_runtimes"]

    class Provider(FakeProvider):
        released = False

        def shutdown(self):
            return self.released

    with tempfile.TemporaryDirectory(prefix="rj-script-", dir="/tmp") as directory:
        root = Path(directory)
        path = root / "local.sock"
        provider = Provider()
        server = runtime.RuntimeServer(path, provider)
        serving = server.run_in_thread()
        try:
            wait_for_socket(path)
            with pytest.raises(SystemExit, match="has not finished shutdown"):
                stop_runtimes(root, timeout=.01)
            assert path.exists() and serving.is_alive()
            provider.released = True
            stop_runtimes(root, timeout=1)
            serving.join(2)
            assert not path.exists() and not serving.is_alive()
        finally:
            provider.released = True
            server.stop()
            serving.join(2)
