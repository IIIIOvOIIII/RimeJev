#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
if [[ " $* " == *" --gate deploy-preflight "* ]] && [[ -n $(git status --porcelain) ]]; then
  printf "Commit the reviewed source before deployment preflight.\n" >&2
  exit 1
fi
.venv/bin/python scripts/quality_gate.py "$@"
if [[ " $* " == *" --gate deploy-preflight "* ]]; then
  .venv/bin/python - <<'PY'
from pathlib import Path
import hashlib,json,subprocess,datetime
root=Path.cwd()
files=subprocess.check_output(['git','ls-files','-z']).decode().split('\0')
h=hashlib.sha256()
for name in sorted(x for x in files if x):
 h.update(name.encode()+b'\0'+(root/name).read_bytes())
app=root/'work/build-probe/Squirrel.app/Contents/MacOS/Squirrel'
p={'commit':subprocess.check_output(['git','rev-parse','HEAD']).decode().strip(),'files_sha256':h.hexdigest(),'binary_sha256':hashlib.sha256(app.read_bytes()).hexdigest(),'passed_at':datetime.datetime.now(datetime.timezone.utc).isoformat()}
(root/'work/evidence/preflight.json').write_text(json.dumps(p,indent=2)+'\n')
PY
fi
