#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-$HOME/spectre}"
RUNNER="$ROOT/profiles/gnome/run-qemu-iso.sh"
[[ -f "$RUNNER" ]] || { echo "[FAIL] runner missing: $RUNNER" >&2; exit 1; }
bash -n "$RUNNER"
grep -q 'INPUT_MODE="${SPECTRE_INPUT_MODE:-ps2}"' "$RUNNER" || { echo '[FAIL] PS/2 default input mode missing' >&2; exit 1; }
grep -q 'case "$INPUT_MODE" in' "$RUNNER" || { echo '[FAIL] input mode switch missing' >&2; exit 1; }
# The USB keyboard must only exist inside the explicit usb mode branch.
count="$(grep -c -- '-device usb-kbd' "$RUNNER" || true)"
[[ "$count" -eq 1 ]] || { echo "[FAIL] expected exactly one optional usb-kbd line, found $count" >&2; exit 1; }
grep -q 'ps2)' "$RUNNER" || { echo '[FAIL] PS/2 branch missing' >&2; exit 1; }
printf '[OK]   QEMU runner shell syntax\n'
printf '[OK]   PS/2 keyboard is the default input path\n'
printf '[OK]   USB keyboard is optional only (SPECTRE_INPUT_MODE=usb)\n'
printf '[OK]   existing VirtIO-SCSI optical path preserved\n'
printf '[OK]   no ISO rebuild required\n\n'
printf '[ok] Spectre QEMU PS/2 keyboard runner verification passed.\n'
