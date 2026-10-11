#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DISK="${SPECTRE_INSTALL_TEST_DISK:-$ROOT/iso/spectre-install-test.qcow2}"
LABEL="${1:-RC4.6-first-proven-install}"
SAFE_LABEL="$(printf '%s' "$LABEL" | tr -cs 'A-Za-z0-9._-' '-')"
OUT_DIR="$ROOT/iso/proven-baselines"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$OUT_DIR/spectre-installed-${SAFE_LABEL}-${STAMP}.qcow2"

[[ -f "$DISK" ]] || { echo "[FAIL] Installed test disk missing: $DISK" >&2; exit 1; }
[[ "$DISK" == "$ROOT/iso/"* ]] || { echo '[FAIL] Refusing to archive a disk outside the Spectre iso/ test area.' >&2; exit 2; }
command -v qemu-img >/dev/null 2>&1 || { echo '[FAIL] qemu-img is required' >&2; exit 1; }
if pgrep -af 'qemu-system-x86_64' | grep -F -- "$DISK" >/dev/null 2>&1; then
  echo '[FAIL] The installed QEMU disk is currently in use. Shut down the VM before freezing it.' >&2
  exit 3
fi

mkdir -p "$OUT_DIR"
echo '[Spectre] Freezing proven installed-QEMU baseline...'
qemu-img check "$DISK"
qemu-img convert -p -O qcow2 -c "$DISK" "$OUT"
qemu-img check "$OUT"
sha256sum "$OUT" > "$OUT.sha256"
qemu-img info "$OUT" > "$OUT.info.txt"
printf '[ok] Proven installed baseline preserved:\n  %s\n' "$OUT"
printf '[ok] SHA-256 sidecar:\n  %s.sha256\n' "$OUT"
