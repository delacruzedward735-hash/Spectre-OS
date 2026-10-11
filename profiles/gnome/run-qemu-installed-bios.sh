#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DISK="${SPECTRE_INSTALL_TEST_DISK:-$ROOT/iso/spectre-install-test.qcow2}"
RAM="${SPECTRE_GNOME_RAM:-6144}"
CPUS="${SPECTRE_GNOME_CPUS:-4}"
[[ -f "$DISK" ]] || { echo "[FAIL] Installed test disk missing: $DISK" >&2; exit 1; }
SERIAL_LOG="$ROOT/iso/spectre-bios-installed-last-boot-serial.log"
: > "$SERIAL_LOG"
printf '[Spectre] BIOS/SeaBIOS installed-system qualification\n'
Q=(qemu-system-x86_64 -machine q35)
if [[ -r /dev/kvm && -w /dev/kvm ]]; then Q+=( -accel kvm -cpu host ); else Q+=( -accel tcg -cpu max ); fi
exec "${Q[@]}" \
  -drive "if=none,id=installed,file=$DISK,format=qcow2" \
  -device virtio-blk-pci,drive=installed,bootindex=1 \
  -boot order=c,menu=off -vga virtio -display gtk,gl=off \
  -device virtio-net-pci,netdev=net0 -netdev user,id=net0 \
  -m "$RAM" -smp "$CPUS",sockets=1,cores="$CPUS",threads=1 \
  -serial "file:$SERIAL_LOG"
