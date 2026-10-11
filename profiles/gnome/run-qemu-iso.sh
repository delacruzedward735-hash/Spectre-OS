#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/config/release.conf"
ISO="${SPECTRE_ISO:-$ROOT/iso/$SPECTRE_ISO_FILENAME}"
DISK="${SPECTRE_INSTALL_TEST_DISK:-$ROOT/iso/spectre-install-test.qcow2}"
DISK_SIZE="${SPECTRE_INSTALL_TEST_SIZE:-48G}"
RAM="${SPECTRE_GNOME_RAM:-6144}"
CPUS="${SPECTRE_GNOME_CPUS:-4}"
OPTICAL_MODE="${SPECTRE_OPTICAL_MODE:-virtio-scsi}"
INPUT_MODE="${SPECTRE_INPUT_MODE:-ps2}"

[[ -f "$ISO" ]] || { echo "[Spectre] ISO not found: $ISO" >&2; exit 1; }
CURRENT_SOURCE_HASH="$("$ROOT/profiles/gnome/runtime-source-hash.sh")"
ISO_SOURCE_HASH="$(awk 'NR==1{print $1}' "$ISO.source-sha256" 2>/dev/null || true)"
if [[ "${SPECTRE_ALLOW_STALE_ISO:-0}" != "1" && "$ISO_SOURCE_HASH" != "$CURRENT_SOURCE_HASH" ]]; then
  echo "[FAIL] ISO is stale or was built before runtime-source stamping." >&2
  echo "       ISO source: ${ISO_SOURCE_HASH:-missing}" >&2
  echo "       Current:    $CURRENT_SOURCE_HASH" >&2
  echo "       Rebuild with: ./profiles/gnome/build-live-iso.sh" >&2
  exit 2
fi
command -v qemu-system-x86_64 >/dev/null || { echo "[Spectre] qemu-system-x86_64 required" >&2; exit 1; }
command -v qemu-img >/dev/null || { echo "[Spectre] qemu-img required" >&2; exit 1; }

if [[ ! -f "$DISK" ]]; then
  echo "[Spectre] Creating safe $DISK_SIZE installer test disk: $DISK"
  qemu-img create -f qcow2 "$DISK" "$DISK_SIZE"
fi

find_first() {
  local p
  for p in "$@"; do
    [[ -f "$p" ]] && { echo "$p"; return 0; }
  done
  return 1
}

CODE="${SPECTRE_OVMF_CODE:-$(find_first /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd || true)}"
VARS_TEMPLATE="${SPECTRE_OVMF_VARS:-$(find_first /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd || true)}"
[[ -f "$CODE" && -f "$VARS_TEMPLATE" ]] || {
  echo "[Spectre] OVMF firmware missing. Install with: sudo apt install ovmf" >&2
  exit 1
}

VARS="$ROOT/iso/OVMF_VARS_SPECTRE_INSTALLER.fd"
if [[ "${SPECTRE_KEEP_NVRAM:-0}" != "1" ]]; then
  cp "$VARS_TEMPLATE" "$VARS"
elif [[ ! -f "$VARS" ]]; then
  cp "$VARS_TEMPLATE" "$VARS"
fi

SERIAL="${SPECTRE_SERIAL:-0}"
SERIAL_LOG="$ROOT/iso/spectre-last-boot-serial.log"

printf '[Spectre] ISO: %s\n' "$ISO"
printf '[Spectre] Optical mode: %s\n' "$OPTICAL_MODE"
printf '[Spectre] Input mode: %s\n' "$INPUT_MODE"
printf '[Spectre] Installer test disk: %s (bootindex=2)\n' "$DISK"
printf '[Spectre] Firmware NVRAM reset for this test: %s\n' "$([[ ${SPECTRE_KEEP_NVRAM:-0} == 1 ]] && echo no || echo yes)"
printf '[Spectre] It is safe to erase this VIRTUAL disk from the installer.\n'

Q=(qemu-system-x86_64 -machine q35)
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  Q+=( -accel kvm -cpu host )
else
  Q+=( -accel tcg -cpu max )
fi

ARGS=(
  -drive "if=pflash,format=raw,readonly=on,file=$CODE"
  -drive "if=pflash,format=raw,file=$VARS"
)

# Default for Spectre live-ISO testing: retain the proven VirtIO-SCSI optical
# path that exposes the CD-ROM as /dev/sr0. AHCI remains available as a
# compatibility override with SPECTRE_OPTICAL_MODE=ahci.
case "$OPTICAL_MODE" in
  ahci)
    ARGS+=(
      -drive "if=none,id=spectrecd,file=$ISO,media=cdrom,format=raw,readonly=on"
      -device "ide-cd,bus=ide.1,drive=spectrecd,bootindex=1"
    )
    ;;
  virtio-scsi)
    ARGS+=(
      -device "virtio-scsi-pci,id=scsi0"
      -drive "if=none,id=spectrecd,file=$ISO,media=cdrom,format=raw,readonly=on"
      -device "scsi-cd,drive=spectrecd,bus=scsi0.0,bootindex=1"
    )
    ;;
  *)
    echo "[Spectre] Unknown SPECTRE_OPTICAL_MODE=$OPTICAL_MODE (use ahci or virtio-scsi)" >&2
    exit 2
    ;;
esac

ARGS+=(
  -drive "if=none,id=installdisk,file=$DISK,format=qcow2"
  -device "virtio-blk-pci,drive=installdisk,bootindex=2"
  -boot menu=on
  -vga virtio
  -display gtk,gl=off
  -device virtio-net-pci,netdev=net0
  -netdev user,id=net0
  -m "$RAM"
  -smp "$CPUS",sockets=1,cores="$CPUS",threads=1
)

# Keep the default keyboard on the legacy PS/2 path. QEMU's usb-kbd device
# overrides the PS/2 keyboard; that is undesirable in a deliberately slim
# early initramfs where USB HID/XHCI modules may not be present yet.
case "$INPUT_MODE" in
  ps2)
    # No explicit USB keyboard: QEMU keeps the emulated PS/2 keyboard.
    ;;
  usb)
    ARGS+=( -device qemu-xhci -device usb-kbd -device usb-tablet )
    ;;
  *)
    echo "[Spectre] Unknown SPECTRE_INPUT_MODE=$INPUT_MODE (use ps2 or usb)" >&2
    exit 2
    ;;
esac

if [[ "$SERIAL" == "1" ]]; then
  ARGS+=( -serial stdio )
else
  : > "$SERIAL_LOG"
  printf '[Spectre] Boot serial log: %s\n' "$SERIAL_LOG"
  ARGS+=( -serial "file:$SERIAL_LOG" )
fi

exec "${Q[@]}" "${ARGS[@]}"
