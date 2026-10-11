#!/usr/bin/env bash
# Read-only verification of the actual SquashFS payload, not just staging.
set -Eeuo pipefail
[[ $# == 4 ]] || { echo 'Usage: verify-packaged-modules.sh SQUASHFS STAGE KREL CANDIDATE' >&2; exit 2; }
SQUASHFS="$1"; STAGE="$(readlink -e "$2")"; KREL="$3"; CANDIDATE="$(readlink -e "$4")"
[[ "$KREL" == '7.1.8-spectre' && -s "$SQUASHFS" ]] || { echo '[STOP] Invalid SquashFS/version.' >&2; exit 1; }
[[ -s "$CANDIDATE/modules.order" ]] || { echo '[STOP] Missing qualified modules.order.' >&2; exit 1; }
command -v unsquashfs >/dev/null || { echo '[STOP] Missing unsquashfs.' >&2; exit 1; }
CANON="$(readlink -e "$STAGE/lib/modules/$KREL")"
case "$CANON" in "$STAGE/"*) ;; *) echo '[STOP] Unsafe staged module path.' >&2; exit 1 ;; esac
PREFIX="${CANON#"$STAGE/"}"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

# If the SquashFS missed the module tree or preserved stale original bytes,
# no ISO should be published. -cat emits the selected file to stdout.
printf '[Spectre] Verifying optimized module metadata embedded in SquashFS...\n'
unsquashfs -cat "$SQUASHFS" "$PREFIX/modules.order" > "$WORK/modules.order" || {
  echo '[STOP] Could not extract SquashFS modules.order.' >&2; exit 1;
}
cmp -s "$CANDIDATE/modules.order" "$WORK/modules.order" || {
  echo '[STOP] Packaged module list is stale or mismatched.' >&2; exit 1;
}
for mod in vmd nvme ahci vmwgfx vboxvideo; do
  SOURCE="$(find "$CANDIDATE/kernel" -type f -name "$mod.ko" -print -quit)"
  [[ -n "$SOURCE" ]] || { echo "[STOP] Required driver absent: $mod" >&2; exit 1; }
  REL="${SOURCE#"$CANDIDATE/"}"
  unsquashfs -cat "$SQUASHFS" "$PREFIX/$REL" > "$WORK/$mod.ko" || {
    echo "[STOP] Driver $mod missing from packaged SquashFS." >&2; exit 1;
  }
  cmp -s "$SOURCE" "$WORK/$mod.ko" || {
    echo "[STOP] Packaged driver $mod does not match qualified bytes." >&2; exit 1;
  }
  printf '[PASS] SquashFS %s.ko matches qualified candidate.\n' "$mod"
done
printf '[PASS] Actual SquashFS contains verified module inventory and five critical driver binaries.\n'
