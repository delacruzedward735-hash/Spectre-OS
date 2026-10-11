#!/usr/bin/env bash
# Called only by the Spectre ISO builder after it copies the source engineering disk.
# Writes ONLY inside the disposable rootfs at $PROJECT/build/.../rootfs.
set -Eeuo pipefail

[[ $# == 3 ]] || { echo 'Usage: verified-module-stage.sh STAGED_ROOT KERNEL_RELEASE QUALIFIED_CANDIDATE' >&2; exit 2; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
STAGE="$(readlink -e "$1")"
KREL="$2"
CANDIDATE="$(readlink -e "$3")"
BASELINE="$ROOT/rootfs-gnome"
AUDITOR="$ROOT/profiles/gnome/audit-module-bridge.py"
RECOVERY_AUDITOR="$ROOT/profiles/gnome/audit-rc1-recovery.py"
RECOVERY_ISO="${SPECTRE_RECOVERY_ISO:-}"

if [[ -n "$RECOVERY_ISO" ]]; then
  [[ -f "$RECOVERY_ISO" ]] || {
    echo "[STOP] Recovery ISO missing: $RECOVERY_ISO" >&2
    exit 1
  }

  RECOVERY_ISO="$(readlink -e "$RECOVERY_ISO")"
fi

[[ "${EUID:-$(id -u)}" != 0 ]] || { echo '[STOP] Run ISO builder as your normal user; it manages its own sudo session.' >&2; exit 1; }
[[ "$KREL" == '7.1.8-spectre' ]] || { echo "[STOP] Unsupported optimized module release: $KREL" >&2; exit 1; }
case "$STAGE/" in "$ROOT/build/"*) ;; *) echo "[STOP] Refusing non-disposable target: $STAGE" >&2; exit 1;; esac
[[ "$STAGE" != "$BASELINE" && "$STAGE" != "$CANDIDATE" ]] || { echo '[STOP] Source and staging path overlap.' >&2; exit 1; }
[[ -d "$STAGE/etc" && -s "$STAGE/boot/vmlinuz-$KREL" ]] || { echo '[STOP] Staged root incomplete.' >&2; exit 1; }
[[ -d "$CANDIDATE/kernel" ]] || {
  echo '[STOP] Qualified candidate missing.' >&2
  exit 1
}

if [[ -n "$RECOVERY_ISO" ]]; then
  [[ -s "$RECOVERY_AUDITOR" ]] || {
    echo '[STOP] RC1 recovery auditor missing.' >&2
    exit 1
  }
else
  [[ -d "$BASELINE/etc" ]] || {
    echo '[STOP] Original baseline missing.' >&2
    exit 1
  }

  [[ -s "$AUDITOR" ]] || {
    echo '[STOP] Stage module auditor missing.' >&2
    exit 1
  }
fi
for command_name in sudo rsync readlink python3 mountpoint findmnt; do
  command -v "$command_name" >/dev/null || { echo "[STOP] Missing $command_name" >&2; exit 1; }
done
DEST="$STAGE/lib/modules/$KREL"
[[ -d "$DEST" && ! -L "$DEST" ]] || { echo '[STOP] Source-image modules missing or linked.' >&2; exit 1; }
CANONICAL_DEST="$(readlink -e "$DEST")"
case "$CANONICAL_DEST/" in "$STAGE/"*) ;; *) echo '[STOP] Unsafe module path escapes stage root.' >&2; exit 1;; esac
if findmnt -rn -o TARGET | grep -Fx "$CANONICAL_DEST" >/dev/null; then
  echo '[STOP] Staging module tree is a mount point.' >&2; exit 1
fi

if [[ -n "$RECOVERY_ISO" ]]; then
  printf '[Spectre] Checking staged source against trusted RC1 ISO recovery provenance...\n'

  sudo python3 "$RECOVERY_AUDITOR" \
    --mode source \
    --candidate "$CANDIDATE" \
    --target "$STAGE" \
    --recovery-iso "$RECOVERY_ISO" \
    --krel "$KREL"
else
  printf '[Spectre] Checking source engineering image against the original signed modules...\n'

  sudo python3 "$AUDITOR" --mode source --candidate "$CANDIDATE" \
    --baseline "$BASELINE" --target "$STAGE" --krel "$KREL"
fi

printf '[Spectre] Overlaying optimized modules ONLY in disposable ISO staging...\n'
sudo rsync -aHAX --numeric-ids --delete -- "$CANDIDATE/" "$DEST/"
sudo chown -R root:root -- "$DEST"
sudo find "$DEST" -type d -exec chmod 0755 {} +
sudo find "$DEST" -type f -exec chmod 0644 {} +
if [[ -n "$RECOVERY_ISO" ]]; then
  sudo python3 "$RECOVERY_AUDITOR" \
    --mode integrated \
    --candidate "$CANDIDATE" \
    --target "$STAGE" \
    --recovery-iso "$RECOVERY_ISO" \
    --krel "$KREL"
else
  sudo python3 "$AUDITOR" --mode integrated --candidate "$CANDIDATE" \
    --baseline "$BASELINE" --target "$STAGE" --krel "$KREL"
fi

echo '[PASS] Qualified compact module collection installed into disposable ISO stage.'
echo '[IMPORTANT] Engineering disk, baseline rootfs and both QEMU images were not modified.'
