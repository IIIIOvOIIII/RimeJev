#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
project_dir=$(pwd)
app_dir="$HOME/Library/Input Methods/Rime-Jev.app"
user_dir="$HOME/Library/Rime-Jev"
if [[ ${1:-} == --rollback ]]; then
  .venv/bin/python scripts/stop_runtime.py
  if [[ -x "$app_dir/Contents/MacOS/Squirrel" ]]; then
    "$app_dir/Contents/MacOS/Squirrel" --disable-input-source
    "$app_dir/Contents/MacOS/Squirrel" --quit
  fi
  '/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel' --enable-input-source
  '/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel' --select-input-source
  printf 'Original Squirrel selected; Rime-Jev data retained for recovery.\n'
  exit 0
fi
if [[ ${1:-} == --validated ]]; then
  .venv/bin/python - <<'CHECK'
import hashlib,json,subprocess
from pathlib import Path
root=Path.cwd();p=json.loads((root/'work/evidence/preflight.json').read_text())
assert p['commit']==subprocess.check_output(['git','rev-parse','HEAD']).decode().strip(), 'Preflight commit differs'
h=hashlib.sha256()
for name in sorted(x for x in subprocess.check_output(['git','ls-files','-z']).decode().split('\0') if x):
 h.update(name.encode()+b'\0'+(root/name).read_bytes())
assert p['files_sha256']==h.hexdigest(), 'Files changed after preflight'
assert p['binary_sha256']==hashlib.sha256((root/'work/build-probe/Squirrel.app/Contents/MacOS/Squirrel').read_bytes()).hexdigest(), 'Build changed after preflight'
CHECK
else
  scripts/run_quality_gate.sh --gate deploy-preflight
fi
source_sha=$(git rev-parse HEAD)
.venv/bin/python scripts/stop_runtime.py
mkdir -p "$HOME/Library/Input Methods" work/backups
restart_existing=false
if [[ -e "$app_dir" ]]; then
  swift scripts/restart_input.swift --stop
  restart_existing=true
  ditto "$app_dir" "work/backups/Rime-Jev-app-$(date +%Y%m%dT%H%M%S)"
fi
if [[ ! -d "$user_dir" ]]; then
  cp -cR "$HOME/Library/Rime" "$user_dir"
fi
.venv/bin/python scripts/prepare_rime.py "$user_dir"
ditto work/build-probe/Squirrel.app "$app_dir"
codesign --verify --deep --strict "$app_dir"
(
  cd "$user_dir"
  "$app_dir/Contents/MacOS/Squirrel" --build
)
# Register and enable a distinct, user-scoped source. Selection is a separate validation step.
swift scripts/register_input.swift
"$app_dir/Contents/MacOS/Squirrel" --register-input-source
"$app_dir/Contents/MacOS/Squirrel" --enable-input-source
.venv/bin/python - "$project_dir" "$source_sha" "$app_dir" "$user_dir" <<'PY'
import json,pathlib,sys,hashlib,datetime
root,sha,app,user=map(str,sys.argv[1:]);p=pathlib.Path(root)
info={'source_commit':sha,'installed_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'app':app,'user_data':user,'bundle_id':'im.lynx.inputmethod.RimeJev','binary_sha256':hashlib.sha256((pathlib.Path(app)/'Contents/MacOS/Squirrel').read_bytes()).hexdigest(),'default_mode':None}
settings=pathlib.Path.home()/'Library/Application Support/Rime-Jev/settings.json'
settings.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
if settings.exists():
 data=json.loads(settings.read_text())
 data['projectRoot']=root
else:
 data={'mode':'off','allowedApps':[],'appModes':{},'projectRoot':root,'modelPath':root+'/work/models/this-that-model-1.2','vaultRef':'typesafe_api_key','localThreshold':0.65,'jevThreshold':0.55}
data.setdefault('training', {'enabled':False,'scope':'selected','includedApps':[],'excludedApps':[]})
settings.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n')
settings.chmod(0o600)
info['default_mode']=data.get('defaultMode','off')
(p/'work/evidence/install.json').write_text(json.dumps(info,indent=2)+'\n')
print(json.dumps(info))
PY
open -g -a "$app_dir"
if [[ "$restart_existing" == true ]]; then
  swift scripts/restart_input.swift --restore
fi
printf 'Installed user-scoped Rime-Jev. Original Squirrel and its data remain available.\n'
