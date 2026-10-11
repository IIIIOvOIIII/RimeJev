"""常驻本机 Unix socket JSON-line runtime for Rime-Jev."""

from __future__ import annotations

import argparse
import json
import os
import signal
import socket
import stat
import threading
import time
from pathlib import Path
from typing import Any

from .providers import (
    JEV_MODEL_ID,
    LOCAL_MODEL_ID,
    MAX_OPTIONS,
    DecisionRequest,
    JevProvider,
    LocalProvider,
    ProviderInputError,
    ProviderResult,
)

MAX_MESSAGE_BYTES = 128 * 1024
MAX_MESSAGE_SIZE = MAX_MESSAGE_BYTES
SOCKET_MODE = 0o600
SOCKET_PARENT_MODE = 0o700
LISTEN_BACKLOG = 16
READ_TIMEOUT_SECONDS = 5.0


def _error_result(provider: str, model: str, request_id: Any, code: str) -> dict[str, Any]:
    return ProviderResult(
        status="error",
        provider=provider,
        model=model,
        error=code,
    ).to_dict(request_id)


class RuntimeServer:
    """One-request-per-connection Unix socket server.

    Provider selection happens in the constructor and cannot be changed by a request.  Connection
    handlers are short-lived threads; inference gates in the provider reject a second task rather
    than allowing an unbounded executor queue.
    """

    def __init__(self, socket_path: str | os.PathLike[str], provider: Any) -> None:
        self.socket_path = Path(socket_path)
        self.provider = provider
        self._listener: socket.socket | None = None
        self._owns_socket = False
        self._stop = threading.Event()
        self._started = False
        self._lock = threading.RLock()
        self._connections: set[threading.Thread] = set()

    @property
    def is_running(self) -> bool:
        return self._started and not self._stop.is_set()

    def start(self) -> None:
        with self._lock:
            if self._started:
                return
            self._prepare_socket_path()
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            listener.settimeout(0.25)
            try:
                listener.bind(str(self.socket_path))
                os.chmod(self.socket_path, SOCKET_MODE)
                listener.listen(LISTEN_BACKLOG)
                self._owns_socket = True
            except Exception:
                listener.close()
                self._unlink_socket()
                raise
            self._listener = listener
            self._started = True
            start = getattr(self.provider, "start", None)
            try:
                if callable(start):
                    start()
            except Exception:
                self._started = False
                listener.close()
                self._listener = None
                self._unlink_socket()
                raise

    def _prepare_socket_path(self) -> None:
        parent = self.socket_path.parent
        parent.mkdir(mode=SOCKET_PARENT_MODE, parents=True, exist_ok=True)
        os.chmod(parent, SOCKET_PARENT_MODE)
        if self.socket_path.exists() or self.socket_path.is_symlink():
            try:
                mode = self.socket_path.stat().st_mode
            except FileNotFoundError:
                mode = 0
            if not stat.S_ISSOCK(mode):
                raise RuntimeError("socket path is not a Unix socket")
            probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                probe.settimeout(0.2)
                probe.connect(str(self.socket_path))
            except (ConnectionRefusedError, FileNotFoundError):
                pass
            else:
                raise RuntimeError("runtime is already running")
            finally:
                probe.close()
            self.socket_path.unlink()

    def serve_forever(self) -> None:
        self.start()
        listener = self._listener
        if listener is None:
            raise RuntimeError("runtime listener is unavailable")
        try:
            while not self._stop.is_set():
                if self.provider.provider_name == "local" and getattr(self.provider, "status", None) == "unloaded":
                    break
                try:
                    connection, _ = listener.accept()
                except OSError:
                    if self._stop.is_set():
                        break
                    continue
                connection.settimeout(READ_TIMEOUT_SECONDS)
                thread = threading.Thread(
                    target=self._handle_connection,
                    args=(connection,),
                    name="rime-jev-client",
                    daemon=True,
                )
                with self._lock:
                    self._connections.add(thread)
                thread.start()
        finally:
            self.stop()

    def run_in_thread(self) -> threading.Thread:
        thread = threading.Thread(target=self.serve_forever, name="rime-jev-runtime", daemon=True)
        thread.start()
        return thread

    def _handle_connection(self, connection: socket.socket) -> None:
        try:
            request_id: Any = None
            try:
                raw = connection.makefile("rb").readline(MAX_MESSAGE_BYTES + 2)
                if not raw:
                    return
                if raw.endswith(b"\n"):
                    body = raw[:-1]
                else:
                    body = raw
                if len(body) > MAX_MESSAGE_BYTES:
                    self._send(connection, _error_result_for_runtime(None, self.provider, "message_too_large"))
                    return
                try:
                    decoded = body.decode("utf-8")
                    request = json.loads(decoded)
                except UnicodeDecodeError:
                    self._send(connection, _error_result_for_runtime(None, self.provider, "invalid_json"))
                    return
                except json.JSONDecodeError:
                    self._send(connection, _error_result_for_runtime(None, self.provider, "invalid_json"))
                    return
                if not isinstance(request, dict):
                    self._send(connection, _error_result_for_runtime(None, self.provider, "invalid_json"))
                    return
                request_id = request.get("id")
                response = self._dispatch(request)
                self._send(connection, response)
                if request.get("op") == "shutdown":
                    # Send the acknowledgement first, then tear down the listener and socket.
                    self.stop()
            except socket.timeout:
                self._send(connection, _error_result_for_runtime(request_id, self.provider, "read_timeout"))
            except (BrokenPipeError, ConnectionResetError):
                return
            except Exception:
                self._send(connection, _error_result_for_runtime(request_id, self.provider, "inference_failed"))
        finally:
            try:
                connection.close()
            finally:
                current = threading.current_thread()
                with self._lock:
                    self._connections.discard(current)

    def _dispatch(self, request: dict[str, Any]) -> dict[str, Any]:
        request_id = request.get("id")
        op = request.get("op")
        if op == "health":
            return self.provider.health().to_dict(request_id)
        if op == "shutdown":
            return ProviderResult(
                status="ready",
                provider=self._provider_name(),
                model=self._model_name(),
                elapsed_ms=0.0,
            ).to_dict(request_id)
        if op != "decide":
            return _error_result(self._provider_name(), self._model_name(), request_id, "unsupported_operation")
        try:
            decision_request = DecisionRequest.from_payload(request)
        except ProviderInputError:
            return _error_result(self._provider_name(), self._model_name(), request_id, "invalid_request")
        return self.provider.decide(decision_request).to_dict(request_id)

    def _send(self, connection: socket.socket, response: dict[str, Any]) -> None:
        payload = json.dumps(response, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")
        connection.sendall(payload + b"\n")

    def _provider_name(self) -> str:
        return str(getattr(self.provider, "provider_name", "unknown"))

    def _model_name(self) -> str:
        return str(getattr(self.provider, "model_name", "unknown"))

    def stop(self) -> None:
        with self._lock:
            if self._stop.is_set() and self._listener is None:
                return
            self._stop.set()
            listener = self._listener
            self._listener = None
        if listener is not None:
            try:
                listener.close()
            except OSError:
                pass
        shutdown = getattr(self.provider, "shutdown", None)
        if callable(shutdown):
            shutdown()
        self._unlink_socket()

    def _unlink_socket(self) -> None:
        with self._lock:
            if not self._owns_socket:
                return
            self._owns_socket = False
        try:
            if self.socket_path.is_socket():
                self.socket_path.unlink()
        except (FileNotFoundError, OSError):
            pass


UnixSocketRuntime = RuntimeServer


def _error_result_for_runtime(request_id: Any, provider: Any, code: str) -> dict[str, Any]:
    name = str(getattr(provider, "provider_name", "unknown"))
    model = str(getattr(provider, "model_name", "unknown"))
    return _error_result(name, model, request_id, code)


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Rime-Jev local Unix socket decision runtime")
    parser.add_argument("--socket", required=True, dest="socket_path")
    parser.add_argument("--provider", required=True, choices=("local", "jev"))
    parser.add_argument("--model-path", dest="model_path")
    parser.add_argument("--vault-ref", dest="vault_ref")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    if args.provider == "local":
        if not args.model_path:
            _build_parser().error("--model-path is required for --provider local")
        provider = LocalProvider(args.model_path)
    else:
        if not args.vault_ref:
            _build_parser().error("--vault-ref is required for --provider jev")
        provider = JevProvider(args.vault_ref)

    server = RuntimeServer(args.socket_path, provider)
    previous_handlers: dict[int, Any] = {}

    def stop_handler(signum: int, frame: Any) -> None:
        server.stop()

    for signum in (signal.SIGINT, signal.SIGTERM):
        try:
            previous_handlers[signum] = signal.signal(signum, stop_handler)
        except ValueError:
            pass
    try:
        server.serve_forever()
    finally:
        server.stop()
        for signum, handler in previous_handlers.items():
            try:
                signal.signal(signum, handler)
            except ValueError:
                pass
    return 0


if __name__ == "__main__":  # pragma: no cover - exercised by the CLI smoke test.
    raise SystemExit(main())


__all__ = ["MAX_MESSAGE_BYTES", "MAX_MESSAGE_SIZE", "RuntimeServer", "UnixSocketRuntime", "main"]
