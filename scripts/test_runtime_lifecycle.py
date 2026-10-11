#!/usr/bin/env python3
"""Exercise native switching against isolated fake sockets; never touch the installed IME."""
from pathlib import Path
import json
import os
import signal
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
(root / 'work').mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='native-lifecycle-', dir=root / 'work') as tmp:
    fixture = Path(tmp)
    (fixture / '.venv/bin').mkdir(parents=True)
    (fixture / '.venv/bin/python').symlink_to(Path(sys.executable).resolve())
    package = fixture / 'src/rime_jev'
    package.mkdir(parents=True)
    (package / '__init__.py').write_text('')
    (fixture / 'sockets').mkdir()
    (package / 'runtime.py').write_text('''import argparse,json,os,socket,time
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--socket');p.add_argument('--provider');p.add_argument('--model-path');p.add_argument('--vault-ref');a=p.parse_args()
log=Path.cwd()/'events.log'
with (Path.cwd()/'pids.log').open('a') as f:f.write(str(os.getpid())+'\\n')
def record(value):
 with log.open('a') as f:f.write(value+'\\n')
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);s.bind(a.socket);s.listen()
record('root '+str(Path.cwd())+' '+os.environ['RIME_JEV_PROJECT_ROOT']);record('start '+a.provider)
while True:
 c,_=s.accept()
 with c:
  request=json.loads(c.makefile('rb').readline())
  response={'id':request['id'],'provider':a.provider,'model':'fixture','status':'ready','probabilities':{}}
  if request['op']=='decide':
   record('decide '+a.provider);time.sleep(.15)
  c.sendall(json.dumps(response).encode()+b'\\n')
 if request['op']=='shutdown':break
s.close()
time.sleep(4 if a.provider=='tev-4b' else .2)
record('released '+a.provider);Path(a.socket).unlink()
''')
    source = (root / 'native/JevIntegration.swift').read_text().split('final class JevInputAdapter')[0]
    marker = 'FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Rime-Jev")'
    assert source.count(marker) == 1
    source = source.replace(marker, 'URL(fileURLWithPath: ' + json.dumps(str(fixture / 'sockets')) + ')')
    extracted = fixture / 'RuntimeUnderTest.swift'
    extracted.write_text(source)
    executable = fixture / 'RuntimeLifecycleTests'
    subprocess.run(['swiftc', '-parse-as-library', str(root / 'native/JevCore.swift'), str(extracted),
                    str(root / 'native/tests/JevRuntimeLifecycleTests.swift'), '-framework', 'AppKit',
                    '-framework', 'InputMethodKit', '-framework', 'Carbon', '-o', str(executable)], check=True, timeout=60)
    try:
        subprocess.run([str(executable), str(fixture)], check=True, timeout=40)
    finally:
        pid_file = fixture / 'pids.log'
        for value in pid_file.read_text().splitlines() if pid_file.exists() else []:
            pid = int(value)
            command = subprocess.run(['ps', '-p', str(pid), '-o', 'command='], capture_output=True, text=True).stdout
            if str(fixture) in command and 'rime_jev.runtime' in command:
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
