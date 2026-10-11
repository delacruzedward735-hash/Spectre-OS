#!/usr/bin/env bash
set -euo pipefail
APPROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$APPROOT" <<'PY'
from pathlib import Path
import importlib.util, sys
sys.dont_write_bytecode = True
root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('managed_app', root/'managed_app.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
rows = m.parse_registry(root/'registry.tsv')
for app_id, version, state, runtime, app_dir in rows:
    d = root/'apps'/app_dir
    conf = m.parse_conf(d/'app.conf')
    assert conf['APP_ID'] == app_id, f'{app_id}: config id mismatch'
    assert conf['APP_VERSION'] == version, f'{app_id}: version mismatch'
    assert conf['APP_STATE'] == state, f'{app_id}: state mismatch'
    assert conf['APP_RUNTIME'] == runtime, f'{app_id}: runtime mismatch'
    entry = d/'payload'/conf['APP_ENTRY']
    assert entry.is_file(), f'{app_id}: entry missing: {conf["APP_ENTRY"]}'
    if runtime.startswith('python-'):
        assert entry.suffix == '.py', f'{app_id}: Python runtime entry must be .py'
    if runtime == 'native-binary':
        assert entry.stat().st_mode & 0o111, f'{app_id}: native entry must be executable'
    icon = conf['APP_ICON_FILE']
    if icon:
        assert (d/icon).is_file(), f'{app_id}: icon missing: {icon}'
    req = conf['APP_REQUIREMENTS']
    if req:
        p = d/req
        assert p.is_file(), f'{app_id}: requirements missing'
        for no, raw in enumerate(p.read_text(encoding='utf-8').splitlines(), 1):
            line=raw.strip()
            if not line or line.startswith('#') or line.startswith('--hash='): continue
            assert not line.startswith(('-r','--requirement','-e','git+','http://','https://')), f'{app_id}: unsafe requirement line {no}'
            assert '==' in line.split(';',1)[0], f'{app_id}: unpinned requirement line {no}'
    forbidden = {'.env','keystore.properties','local.properties'}
    secret_ext = {'.jks','.keystore','.p12','.pfx','.pem','.key'}
    for f in d.rglob('*'):
        if not f.is_file(): continue
        assert f.name not in forbidden and f.suffix.lower() not in secret_ext, f'{app_id}: secret-bearing file bundled: {f.relative_to(d)}'
print(f'[PASS] managed app registry parsed: {len(rows)} app(s)')
print('[PASS] managed app metadata/payload/security validation')
PY
