#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Hash only inputs that can change the installed/live runtime or the image
# assembly contract. Generated images, logs, caches and documentation are
# deliberately excluded.
inputs=(
  "$ROOT/VERSION"
  "$ROOT/config/release.conf"
  "$ROOT/kernel/spectre-required.config"
  "$ROOT/profiles/gnome/branding"
  "$ROOT/profiles/gnome/installer"
  "$ROOT/profiles/gnome/personal-apps"
  "$ROOT/profiles/gnome/create-rootfs.sh"
  "$ROOT/profiles/gnome/install-branding.sh"
  "$ROOT/profiles/gnome/install-boot-branding.sh"
  "$ROOT/profiles/gnome/finalize-spectre-identity.sh"
  "$ROOT/profiles/gnome/clean-product-rootfs.sh"
  "$ROOT/profiles/gnome/sanitize-runtime-state.sh"
  "$ROOT/profiles/gnome/sync-runtime-root.sh"
  "$ROOT/profiles/gnome/build-live-iso.sh"
  "$ROOT/profiles/gnome/release-check.sh"
  "$ROOT/profiles/gnome/verified-module-stage.sh"
  "$ROOT/profiles/gnome/audit-module-bridge.py"
  "$ROOT/profiles/gnome/audit-rc1-recovery.py"
  "$ROOT/profiles/gnome/verify-packaged-modules.sh"
  "$ROOT/profiles/gnome/build-uefi.sh"
  "$ROOT/profiles/gnome/make-uefi-disk-image.sh"
)

python3 - "$ROOT" "${inputs[@]}" <<'PY'
from pathlib import Path
import hashlib, sys
root = Path(sys.argv[1]).resolve()
files = []
for raw in sys.argv[2:]:
    p = Path(raw)
    if p.is_dir():
        files.extend(
            x for x in p.rglob('*')
            if x.is_file()
            and '__pycache__' not in x.parts
            and x.suffix not in {'.pyc', '.pyo'}
        )
    elif p.is_file():
        files.append(p)
    else:
        raise SystemExit(f"[FAIL] runtime hash input missing: {p}")
files = sorted({p.resolve() for p in files}, key=lambda p: str(p.relative_to(root)))
outer = hashlib.sha256()
for p in files:
    rel = p.relative_to(root).as_posix().encode()
    digest = hashlib.sha256(p.read_bytes()).hexdigest().encode()
    outer.update(rel + b'\0' + digest + b'\n')
print(outer.hexdigest())
PY
