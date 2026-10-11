#!/usr/bin/env python3
"""Stop only Rime-Jev's private runtime sockets before replacing the application."""
import socket
from pathlib import Path
root=Path.home()/'Library/Application Support/Rime-Jev'
for provider in ['local','jev']:
 path=root/(provider+'.sock')
 if not path.exists():continue
 try:
  with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as client:
   client.settimeout(2);client.connect(str(path));client.sendall(b'{"id":"deployment-stop","op":"shutdown"}\n');client.recv(4096)
 except (ConnectionRefusedError,FileNotFoundError):pass
