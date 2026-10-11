#!/usr/bin/env python3
"""Compile only the repository's synthetic Rime data in a disposable work dir."""

import os
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / 'tests/fixtures/rime'
SQUIRREL = Path('/Library/Input Methods/Squirrel.app/Contents')


def prepare_fixture(destination: Path, translator: str = 'script_translator') -> dict:
    """Return build evidence; the caller owns this new, disposable destination."""
    destination = destination.resolve()
    if not destination.is_relative_to((ROOT / 'work').resolve()):
        raise ValueError('Synthetic fixtures may only be staged under this project\'s work directory')
    if translator not in ('script_translator', 'table_translator'):
        raise ValueError(f'Unsupported fixture translator: {translator}')
    bridge = ROOT / 'rime/lua/jev'
    if not (bridge / 'bridge.lua').is_file():
        raise FileNotFoundError(f'Public Lua bridge is missing: {bridge / "bridge.lua"}')
    deployer = SQUIRREL / 'MacOS/rime_deployer'
    if not deployer.is_file():
        raise FileNotFoundError(f'Install Squirrel before running the real-Rime regression: {deployer}')
    destination.mkdir(parents=True, exist_ok=False)
    for source in sorted(FIXTURE.glob('*.yaml')):
        shutil.copyfile(source, destination / source.name)
    if translator == 'table_translator':
        schema = destination / 'wanxiang.schema.yaml'
        original = schema.read_text()
        if original.count('    - script_translator\n') != 1:
            raise ValueError('Expected exactly one script translator in the source fixture')
        schema.write_text(original.replace('    - script_translator\n', '    - table_translator\n'))
    shutil.copytree(bridge, destination / 'lua/jev')
    shared = destination / 'shared'
    shared.mkdir()
    # An empty shared directory prevents fallback to installed dictionaries,
    # essay models, customizations or any user's Rime directory.
    result = subprocess.run(
        [str(deployer), '--build', str(destination), str(shared), str(destination / 'build')],
        cwd=destination, env=dict(os.environ, GLOG_logtostderr='1'),
        capture_output=True, text=True, timeout=30,
    )
    if result.returncode:
        raise RuntimeError(f'Synthetic Rime compilation failed:\n{result.stdout}\n{result.stderr}')
    for name in ('wanxiang.schema.yaml', 'bridge_fixture.table.bin', 'bridge_fixture.prism.bin'):
        if not (destination / 'build' / name).is_file():
            raise RuntimeError(f'Synthetic Rime compiler did not produce {name}:\n{result.stderr}')
    return {'command': [str(deployer), '--build', '<fixture>', '<empty shared>', '<fixture>/build'],
            'stdout': result.stdout, 'stderr': result.stderr}
