#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/config/release.conf"
ISO="${SPECTRE_ISO:-$ROOT/iso/$SPECTRE_ISO_FILENAME}"
DISK="${SPECTRE_INSTALL_TEST_DISK:-$ROOT/iso/spectre-install-test.qcow2}"
RAM="${SPECTRE_GNOME_RAM:-6144}"
CPUS="${SPECTRE_GNOME_CPUS:-4}"
[[ -f "$ISO" ]] || { echo "[FAIL] ISO missing: $ISO" >&2; exit 1; }
[[ -f "$DISK" ]] || { echo "[FAIL] Test disk missing: $DISK (run reset-qemu-install-test.sh first)" >&2; exit 1; }
CURRENT_SOURCE_HASH="$("$ROOT/profiles/gnome/runtime-source-hash.sh")"
ISO_SOURCE_HASH="$(awk 'NR==1{print $1}' "$ISO.source-sha256" 2>/dev/null || true)"
[[ "$ISO_SOURCE_HASH" == "$CURRENT_SOURCE_HASH" ]] || { echo '[FAIL] ISO source hash is stale' >&2; exit 2; }
SERIAL_LOG="$ROOT/iso/spectre-bios-installer-last-boot-serial.log"
: > "$SERIAL_LOG"
printf '[Spectre] BIOS/SeaBIOS installer qualification\n'
printf '[Spectre] Safe virtual target: %s\n' "$DISK"
Q=(qemu-system-x86_64 -machine q35)
if [[ -r /dev/kvm && -w /dev/kvm ]]; then Q+=( -accel kvm -cpu host ); else Q+=( -accel tcg -cpu max ); fi
exec "${Q[@]}" \
  -device virtio-scsi-pci,id=scsi0 \
  -drive "if=none,id=spectrecd,file=$ISO,media=cdrom,format=raw,readonly=on" \
  -device scsi-cd,drive=spectrecd,bus=scsi0.0,bootindex=1 \
  -drive "if=none,id=installdisk,file=$DISK,format=qcow2" \
  -device virtio-blk-pci,drive=installdisk,bootindex=2 \
  -boot menu=on -vga virtio -display gtk,gl=off \
  -device virtio-net-pci,netdev=net0 -netdev user,id=net0 \
  -m "$RAM" -smp "$CPUS",sockets=1,cores="$CPUS",threads=1 \
  -serial "file:$SERIAL_LOG"
