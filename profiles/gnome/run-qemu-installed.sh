#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DISK="${SPECTRE_INSTALL_TEST_DISK:-$ROOT/iso/spectre-install-test.qcow2}"
RAM="${SPECTRE_GNOME_RAM:-6144}"
CPUS="${SPECTRE_GNOME_CPUS:-4}"
[[ -f "$DISK" ]] || { echo "[FAIL] Installed test disk missing: $DISK" >&2; exit 1; }
command -v qemu-system-x86_64 >/dev/null || { echo '[FAIL] qemu-system-x86_64 missing' >&2; exit 1; }
find_first(){ local p; for p in "$@"; do [[ -f "$p" ]] && { echo "$p"; return 0; }; done; return 1; }
CODE="${SPECTRE_OVMF_CODE:-$(find_first /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd || true)}"
VARS_TEMPLATE="${SPECTRE_OVMF_VARS:-$(find_first /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd || true)}"
[[ -f "$CODE" && -f "$VARS_TEMPLATE" ]] || { echo '[FAIL] OVMF firmware missing' >&2; exit 1; }
VARS="$ROOT/iso/OVMF_VARS_SPECTRE_INSTALLED.fd"
cp "$VARS_TEMPLATE" "$VARS"
SERIAL_LOG="$ROOT/iso/spectre-installed-last-boot-serial.log"
: > "$SERIAL_LOG"
Q=(qemu-system-x86_64 -machine q35)
if [[ -r /dev/kvm && -w /dev/kvm ]]; then Q+=( -accel kvm -cpu host ); else Q+=( -accel tcg -cpu max ); fi
exec "${Q[@]}" \
  -drive "if=pflash,format=raw,readonly=on,file=$CODE" \
  -drive "if=pflash,format=raw,file=$VARS" \
  -drive "if=none,id=installed,file=$DISK,format=qcow2" \
  -device virtio-blk-pci,drive=installed,bootindex=1 \
  -vga virtio -display gtk,gl=off \
  -device virtio-net-pci,netdev=net0 -netdev user,id=net0 \
  -m "$RAM" -smp "$CPUS",sockets=1,cores="$CPUS",threads=1 \
  -serial "file:$SERIAL_LOG" -boot order=c,menu=off
