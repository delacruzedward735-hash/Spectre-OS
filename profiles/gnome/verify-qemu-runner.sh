#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-$HOME/spectre}"
F="$ROOT/profiles/gnome/run-qemu-iso.sh"
[[ -f "$F" ]] || { echo "[FAIL] runner missing: $F" >&2; exit 1; }
ok(){ printf '[OK]   %s\n' "$*"; }
bad(){ printf '[FAIL] %s\n' "$*" >&2; exit 1; }
bash -n "$F" && ok 'QEMU runner shell syntax' || bad 'QEMU runner shell syntax'
grep -q 'SPECTRE_OPTICAL_MODE:-virtio-scsi' "$F" && ok 'VirtIO-SCSI is the proven default optical mode' || bad 'VirtIO-SCSI default missing'
grep -q 'ide-cd,bus=ide.1,drive=spectrecd,bootindex=1' "$F" && ok 'q35 SATA/AHCI fallback retained' || bad 'AHCI fallback missing'
grep -q 'virtio-blk-pci,drive=installdisk,bootindex=2' "$F" && ok 'installer disk bootindex=2' || bad 'installer disk bootindex missing'
grep -q 'virtio-scsi)' "$F" && ok 'virtio-scsi fallback retained' || bad 'virtio-scsi fallback missing'
if grep -E '^[[:space:]]*-boot[[:space:]]+order=' "$F" >/dev/null; then bad 'mixed -boot order= with bootindex'; else ok 'no mixed -boot order= with bootindex'; fi
printf '\n[ok] Spectre QEMU live-media runner verification passed.\n'
