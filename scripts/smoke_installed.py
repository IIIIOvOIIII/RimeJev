#!/usr/bin/env python3
"""Read-only installation checks; live typing is verified separately."""
import hashlib,json,plistlib,subprocess
from pathlib import Path
root=Path(__file__).resolve().parents[1]
app=Path.home()/'Library/Input Methods/Rime-Jev.app'
user=Path.home()/'Library/Rime-Jev'
info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier']=='im.lynx.inputmethod.RimeJev'
assert info['InputMethodConnectionName']=='RimeJev_Connection'
assert info['CFBundleDisplayName']=='鼠须管 Jev'
assert info['CFBundleName']=='鼠须管 Jev'
for localization in (app/'Contents/Resources').glob('*.lproj/InfoPlist.strings'):
    names=plistlib.loads(localization.read_bytes())
    for key in ('CFBundleName','CFBundleDisplayName','im.lynx.inputmethod.RimeJev','im.lynx.inputmethod.RimeJev.Hans'):
        assert names[key]=='鼠须管 Jev', (localization,key)
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True,capture_output=True)
assert 'lua_filter@*jev.bridge' in (user/'build/wanxiang.schema.yaml').read_text()
assert (user/'lua/jev/bridge.lua').read_bytes()==(root/'rime/lua/jev/bridge.lua').read_bytes(), 'Installed candidate placement differs from source'
install=json.loads((root/'work/evidence/install.json').read_text())
assert hashlib.sha256((app/'Contents/MacOS/Squirrel').read_bytes()).hexdigest()==install['binary_sha256']
sources=json.loads(subprocess.check_output(['swift',str(root/'scripts/input_sources.swift')]))
assert any(x['id']=='im.lynx.inputmethod.RimeJev.Hans' and x['enabled'] and x['name']=='鼠须管 Jev' for x in sources)
# Coexistence is supported. Never require disabling the user's other input methods.
original=Path('/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel')
backup=root/'work/backups/pre-install/Squirrel.app/Contents/MacOS/Squirrel'
assert hashlib.sha256(original.read_bytes()).digest()==hashlib.sha256(backup.read_bytes()).digest()
print(json.dumps({'installed':True,'signature':True,'schema_bridge':True,'bridge_source_matches':True,'input_source_enabled':True,'localized_name':'鼠须管 Jev','original_binary_unchanged':True,'scope':'read-only installation; not typing acceptance'}))
