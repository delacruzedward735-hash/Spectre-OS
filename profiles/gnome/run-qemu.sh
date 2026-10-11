#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEFAULT_KERNEL="$HOME/linux-7.1.8/arch/x86/boot/bzImage"
KERNEL="${1:-${SPECTRE_KERNEL:-$DEFAULT_KERNEL}}"
IMAGE="${SPECTRE_GNOME_IMAGE:-$ROOT/iso/spectre-gnome.img}"
RAM="${SPECTRE_GNOME_RAM:-4096}"
CPUS="${SPECTRE_GNOME_CPUS:-4}"

[[ -f "$KERNEL" ]] || { echo "Kernel not found: $KERNEL" >&2; exit 1; }
[[ -f "$IMAGE" ]] || { echo "GNOME disk image not found: $IMAGE" >&2; exit 1; }
command -v qemu-system-x86_64 >/dev/null 2>&1 || {
    echo "qemu-system-x86_64 is required." >&2
    exit 1
}

QEMU=(qemu-system-x86_64)

# Use KVM when available, otherwise fall back to TCG so the image remains portable.
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    QEMU+=( -enable-kvm -cpu host )
    echo "[Spectre] QEMU acceleration: KVM"
else
    QEMU+=( -cpu max )
    echo "[Spectre] QEMU acceleration: TCG (KVM unavailable)"
fi

# GNOME benefits substantially from VirGL/OpenGL acceleration. Use the GL
# virtio-gpu device when this QEMU build exposes it, otherwise keep a normal
# virtio GPU so the desktop can still use software rendering.
if qemu-system-x86_64 -device help 2>/dev/null | grep -q 'virtio-gpu-gl-pci'; then
    GPU=( -vga none -device virtio-gpu-gl-pci -display gtk,gl=on,zoom-to-fit=on )
    echo "[Spectre] GPU: virtio-gpu-gl-pci (VirGL path)"
elif qemu-system-x86_64 -device help 2>/dev/null | grep -q 'virtio-vga-gl'; then
    GPU=( -device virtio-vga-gl -display gtk,gl=on,zoom-to-fit=on )
    echo "[Spectre] GPU: virtio-vga-gl (VirGL path)"
else
    GPU=( -vga none -device virtio-gpu-pci -display gtk,zoom-to-fit=on )
    echo "[Spectre] GPU: virtio-gpu-pci (software rendering fallback)"
fi

exec "${QEMU[@]}" \
  -machine q35 \
  -kernel "$KERNEL" \
  -append "root=/dev/vda rw rootfstype=ext4 console=ttyS0,115200 systemd.unit=graphical.target systemd.show_status=auto" \
  -drive file="$IMAGE",format=raw,if=virtio,cache=writeback \
  "${GPU[@]}" \
  -device qemu-xhci \
  -device usb-kbd \
  -device usb-tablet \
  -device virtio-net-pci,netdev=net0 \
  -netdev user,id=net0 \
  -m "$RAM" \
  -smp "$CPUS" \
  -serial stdio \
  -no-reboot
