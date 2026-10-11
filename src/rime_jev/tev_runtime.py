"""Own a separate, loopback-only Ollama; call startup from a background worker.

This module never installs software, pulls models, or stops any process.
"""

from __future__ import annotations

import fcntl
import json
import math
import os
import socket
import subprocess
import time
import urllib.error
import urllib.request
from contextlib import contextmanager
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
RUNTIME_ROOT = REPO_ROOT / "work/runtime"
OLLAMA_VERSION = "0.40.3"
OLLAMA_BINARY = RUNTIME_ROOT / "ollama" / OLLAMA_VERSION / "bin/ollama"
OLLAMA_MODELS = REPO_ROOT / "work/models/ollama"
TEV_BASE_URL = "http://127.0.0.1:11435"
PID_RECEIPT_PATH = RUNTIME_ROOT / "tev-ollama.json"
LOCK_PATH = RUNTIME_ROOT / "tev-ollama.lock"
_HOST = "127.0.0.1"
_PORT = 11435
_CHILDREN: list[subprocess.Popen] = []


class TevRuntimeError(RuntimeError):
    """A fixed error code, with no model input or upstream error text."""


def validate_tev_base_url(base_url: str) -> str:
    if base_url != "http://127.0.0.1:11435":
        raise TevRuntimeError("invalid_tev_endpoint")
    return base_url


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise TevRuntimeError("tev_redirect_refused")


def open_tev_api(path: str, *, base_url: str = TEV_BASE_URL, data=None, timeout=1.0):
    """Open only the private API, without proxies or redirects; caller closes it."""
    validate_tev_base_url(base_url)
    if path not in {"/api/version", "/api/tags", "/api/pull"}:
        raise TevRuntimeError("invalid_tev_api_path")
    request = urllib.request.Request(
        base_url + path,
        data=None if data is None else json.dumps(data).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())
    return opener.open(request, timeout=timeout)


def _remaining(deadline: float) -> float:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TevRuntimeError("tev_startup_timeout")
    return remaining


@contextmanager
def runtime_lock(deadline: float):
    RUNTIME_ROOT.mkdir(parents=True, exist_ok=True)
    fd = os.open(LOCK_PATH, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "a+") as handle:
        while True:
            _remaining(deadline)
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                time.sleep(min(0.05, _remaining(deadline)))
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def _inspect(argv: list[str], deadline: float) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(
            argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True,
            timeout=min(1.0, _remaining(deadline)), check=False,
        )
    except subprocess.TimeoutExpired:
        raise TevRuntimeError("tev_process_inspection_timeout") from None


def _process_started(pid: int, deadline: float) -> str | None:
    result = _inspect(["/bin/ps", "-ww", "-p", str(pid), "-o", "uid=,lstart=,command="], deadline)
    if result.returncode == 1 and not result.stdout.strip():
        return None
    fields = result.stdout.strip().split(None, 6)
    if (result.returncode != 0 or len(fields) != 7 or fields[0] != str(os.getuid())
            or fields[6] != f"{OLLAMA_BINARY} serve"):
        return None
    executable = _inspect(
        ["/usr/sbin/lsof", "-a", "-p", str(pid), "-d", "txt", "-Fn"], deadline,
    )
    if executable.returncode != 0 or f"n{OLLAMA_BINARY}" not in executable.stdout.splitlines():
        return None
    return " ".join(fields[1:6])


def _listeners(deadline: float) -> set[tuple[int, str]]:
    result = _inspect(
        ["/usr/sbin/lsof", "-nP", f"-iTCP:{_PORT}", "-sTCP:LISTEN", "-Fpn"], deadline,
    )
    if result.returncode == 1 and not result.stdout.strip():
        return set()
    if result.returncode != 0:
        raise TevRuntimeError("tev_port_inspection_failed")
    listeners = set()
    pid = None
    for line in result.stdout.splitlines():
        if line.startswith("p"):
            try:
                pid = int(line[1:])
            except ValueError:
                raise TevRuntimeError("tev_port_inspection_failed") from None
        elif line.startswith("n") and pid is not None:
            listeners.add((pid, line[1:]))
    if not listeners:
        raise TevRuntimeError("tev_port_inspection_failed")
    return listeners


def _read_receipt() -> dict | None:
    try:
        with PID_RECEIPT_PATH.open("rb") as handle:
            data = handle.read(4097)
        receipt = json.loads(data) if len(data) <= 4096 else None
    except (OSError, ValueError):
        return None
    if not isinstance(receipt, dict):
        return None
    if (type(receipt.get("pid")) is not int or receipt["pid"] <= 1
            or receipt.get("binary") != str(OLLAMA_BINARY)
            or receipt.get("base_url") != TEV_BASE_URL
            or receipt.get("models") != str(OLLAMA_MODELS)
            or receipt.get("version") != OLLAMA_VERSION
            or not isinstance(receipt.get("started"), str)):
        return None
    return receipt


def _write_receipt(pid: int, started: str) -> None:
    receipt = {
        "pid": pid, "binary": str(OLLAMA_BINARY), "base_url": TEV_BASE_URL,
        "models": str(OLLAMA_MODELS), "version": OLLAMA_VERSION, "started": started,
    }
    temporary = PID_RECEIPT_PATH.with_suffix(".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as handle:
        json.dump(receipt, handle)
        handle.write("\n")
    temporary.replace(PID_RECEIPT_PATH)


def _ready(deadline: float) -> bool:
    try:
        with open_tev_api("/api/version", timeout=min(0.5, _remaining(deadline))) as response:
            data = bytearray()
            while len(data) <= 4096:
                _remaining(deadline)
                chunk = response.read1(4097 - len(data))
                if not chunk:
                    break
                data.extend(chunk)
        version = json.loads(data) if len(data) <= 4096 else None
    except (OSError, ValueError, urllib.error.URLError):
        return False
    if not isinstance(version, dict) or version.get("version") != OLLAMA_VERSION:
        raise TevRuntimeError("tev_version_mismatch")
    return True


def _server_environment() -> dict[str, str]:
    # Discard inherited Ollama settings (including remote hosts and debug flags).
    env = {key: value for key, value in os.environ.items() if not key.startswith("OLLAMA_")}
    env.update({
        "OLLAMA_HOST": "127.0.0.1:11435", "OLLAMA_MODELS": str(OLLAMA_MODELS),
        "OLLAMA_NO_CLOUD": "1", "OLLAMA_MAX_LOADED_MODELS": "1",
        "OLLAMA_NUM_PARALLEL": "1", "OLLAMA_MAX_QUEUE": "1",
        "OLLAMA_CONTEXT_LENGTH": "2048", "OLLAMA_KEEP_ALIVE": "10m",
    })
    return env


def ensure_tev_server(*, startup_timeout: float = 10.0) -> str:
    """Start/reuse the owned pinned executable within a bounded caller-side wait.

    Call from the provider's background worker, never the input-event thread.
    An occupied unowned port fails closed. No downloading or process killing.
    """
    validate_tev_base_url(TEV_BASE_URL)
    if not math.isfinite(startup_timeout) or not 0 < startup_timeout <= 30:
        raise TevRuntimeError("invalid_tev_startup_timeout")
    deadline = time.monotonic() + startup_timeout
    if (not OLLAMA_BINARY.is_file() or not os.access(OLLAMA_BINARY, os.X_OK)
            or OLLAMA_BINARY.resolve() != OLLAMA_BINARY):
        raise TevRuntimeError("tev_runtime_not_installed")
    with runtime_lock(deadline):
        _CHILDREN[:] = [child for child in _CHILDREN if child.poll() is None]
        receipt = _read_receipt()
        owned = bool(receipt and _process_started(receipt["pid"], deadline) == receipt["started"])
        listeners = _listeners(deadline)
        if listeners and (not owned or listeners != {(receipt["pid"], f"{_HOST}:{_PORT}")}):
            raise TevRuntimeError("tev_port_unowned")
        child = None
        if owned:
            pid, started = receipt["pid"], receipt["started"]
        else:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
                try:
                    probe.bind((_HOST, _PORT))
                except OSError:
                    raise TevRuntimeError("tev_port_unowned") from None
            OLLAMA_MODELS.mkdir(parents=True, exist_ok=True)
            child = subprocess.Popen(
                [str(OLLAMA_BINARY), "serve"], cwd=OLLAMA_BINARY.parent,
                env=_server_environment(), stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                start_new_session=True, close_fds=True,
            )
            _CHILDREN.append(child)
            pid, started = child.pid, None
        while True:
            _remaining(deadline)
            if child is not None and child.poll() is not None:
                raise TevRuntimeError("tev_start_failed")
            observed = _process_started(pid, deadline)
            if started is None and observed is not None:
                started = observed
                _write_receipt(pid, started)
            if started is not None and observed != started:
                raise TevRuntimeError("tev_process_changed")
            listeners = _listeners(deadline)
            if listeners and listeners != {(pid, f"{_HOST}:{_PORT}")}:
                raise TevRuntimeError("tev_port_unowned")
            if started and listeners and _ready(deadline):
                return TEV_BASE_URL
            time.sleep(min(0.05, _remaining(deadline)))


__all__ = [
    "ensure_tev_server", "TevRuntimeError", "TEV_BASE_URL", "OLLAMA_VERSION",
    "OLLAMA_BINARY", "OLLAMA_MODELS", "PID_RECEIPT_PATH", "open_tev_api",
    "validate_tev_base_url",
]
