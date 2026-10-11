#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DISK="$ROOT/iso/spectre-install-test.qcow2"
SIZE="${SPECTRE_INSTALL_TEST_SIZE:-48G}"
VARS1="$ROOT/iso/OVMF_VARS_SPECTRE_INSTALLER.fd"
VARS2="$ROOT/iso/OVMF_VARS_SPECTRE_INSTALLED.fd"

[[ "$DISK" == "$ROOT/iso/spectre-install-test.qcow2" ]] || { echo '[FAIL] unsafe test-disk path' >&2; exit 2; }
command -v qemu-img >/dev/null 2>&1 || { echo '[FAIL] qemu-img is required' >&2; exit 1; }
mkdir -p "$ROOT/iso"
rm -f -- "$DISK" "$VARS1" "$VARS2"
qemu-img create -f qcow2 "$DISK" "$SIZE"
printf '[ok] Fresh disposable Spectre installer test disk created:\n  %s (%s)\n' "$DISK" "$SIZE"
printf 'This script never targets a physical disk.\n'
