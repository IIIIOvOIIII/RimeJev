#!/usr/bin/env python3
"""Install the pinned public model, verifying Git/LFS content hashes."""
import argparse, hashlib, json, os, shutil
from pathlib import Path
os.environ['HF_HUB_DISABLE_IMPLICIT_TOKEN']='1'
os.environ['HF_HUB_DISABLE_TELEMETRY']='1'
os.environ.pop('HF_HUB_OFFLINE',None)
from huggingface_hub import HfApi,snapshot_download
REPO='flock-io/this-that-model-1.2'
REVISION='c4d1c30b8d512d278726de439b8cc81fccc70c8f'
p=argparse.ArgumentParser();p.add_argument('--destination',type=Path,default=Path(__file__).resolve().parents[1]/'work/models/this-that-model-1.2');a=p.parse_args()
a.destination.mkdir(parents=True,exist_ok=True)
info=HfApi(token=False).model_info(REPO,revision=REVISION,files_metadata=True)
assert info.sha==REVISION
files=[x for x in info.siblings if x.rfilename.endswith(('.json','.safetensors','.jinja'))]
needed=sum(x.size or 0 for x in files if not (a.destination/x.rfilename).exists())
if shutil.disk_usage(a.destination).free<needed+2*1024**3:raise SystemExit('Insufficient free disk space')
print(json.dumps({'stage':'download','files':len(files),'remaining_bytes':needed}),flush=True)
snapshot_download(REPO,revision=REVISION,local_dir=a.destination,allow_patterns=[x.rfilename for x in files],token=False,max_workers=3)
manifest=[]
for f in files:
 path=a.destination/f.rfilename
 lfs=f.lfs
 if lfs:
  expected=lfs.sha256 if hasattr(lfs,'sha256') else lfs['sha256'];h=hashlib.sha256()
 else:
  expected=f.blob_id;h=hashlib.sha1();h.update(f'blob {path.stat().st_size}\0'.encode())
 with path.open('rb') as stream:
  while chunk:=stream.read(4*1024*1024):h.update(chunk)
 if h.hexdigest()!=expected:raise SystemExit('Model file integrity check failed: '+f.rfilename)
 manifest.append({'file':f.rfilename,'size':path.stat().st_size,'hash':expected,'algorithm':'sha256' if lfs else 'git-sha1'})
(a.destination/'rime-jev-manifest.json').write_text(json.dumps({'repository':REPO,'revision':REVISION,'files':manifest},indent=2)+'\n')
print(json.dumps({'stage':'verified','files':len(manifest),'revision':REVISION}),flush=True)
