#!/usr/bin/env python3
"""Stop only RimeJev runtime sockets and await their model release before replacement."""
import socket
import time
from pathlib import Path

def stop_runtimes(root: Path, *, timeout: float = 70) -> None:
    pending = []
    for provider in ['local', 'tev-0.8b', 'tev-4b', 'jev']:
        path = root / (provider + '.sock')
        if not path.exists():
            continue
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(2)
                client.connect(str(path))
                client.sendall(b'{"id":"deployment-stop","op":"shutdown"}\n')
                client.recv(4096)
        except (ConnectionRefusedError, FileNotFoundError):
            # A present socket is still pending, even if its listener refuses connections.
            pass
        except OSError:
            raise SystemExit('Unable to stop the selected RimeJev runtime; installation stopped.') from None
        pending.append(path)
    deadline = time.monotonic() + timeout
    while any(path.exists() for path in pending):
        if time.monotonic() >= deadline:
            raise SystemExit('A RimeJev runtime has not finished shutdown; installation stopped.')
        time.sleep(.05)


if __name__ == '__main__':
    stop_runtimes(Path.home() / 'Library/Application Support/Rime-Jev')
