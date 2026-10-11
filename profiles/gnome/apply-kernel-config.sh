#!/usr/bin/env bash
set -euo pipefail

KERNEL_TREE="${1:-$HOME/linux-7.1.8}"
CONFIG_TOOL="$KERNEL_TREE/scripts/config"

[[ -d "$KERNEL_TREE" ]] || { echo "Kernel tree not found: $KERNEL_TREE" >&2; exit 1; }
[[ -x "$CONFIG_TOOL" ]] || { echo "Kernel scripts/config not found: $CONFIG_TOOL" >&2; exit 1; }
[[ -f "$KERNEL_TREE/.config" ]] || { echo "Kernel .config not found: $KERNEL_TREE/.config" >&2; exit 1; }

required=(
  DEVTMPFS DEVTMPFS_MOUNT PROC_FS SYSFS TMPFS TMPFS_POSIX_ACL TMPFS_XATTR EXT4_FS
  PCI EFI EFI_PARTITION EFIVAR_FS VFAT_FS VIRTIO VIRTIO_PCI VIRTIO_BLK
  DRM DRM_VIRTIO_GPU
  INPUT_EVDEV INPUT_KEYBOARD INPUT_MOUSE
  USB_SUPPORT USB_XHCI_HCD USB_HID HID_GENERIC
  NET UNIX INET VIRTIO_NET
  SERIAL_8250 SERIAL_8250_CONSOLE
  VT VT_CONSOLE UNIX98_PTYS
  CGROUPS NAMESPACES USER_NS PID_NS NET_NS UTS_NS IPC_NS
  SECCOMP SECCOMP_FILTER INOTIFY_USER FANOTIFY
)

for opt in "${required[@]}"; do
    echo "[kernel] enable CONFIG_$opt=y"
    "$CONFIG_TOOL" --enable "$opt"
done

# Audio is useful on a desktop but not required for the first graphical boot.
for opt in SND SND_HDA_INTEL; do
    echo "[kernel] enable desktop audio CONFIG_$opt=y"
    "$CONFIG_TOOL" --enable "$opt"
done

make -C "$KERNEL_TREE" olddefconfig

echo
echo "[ok] Spectre GNOME kernel configuration applied."
echo "Verify: ./profiles/gnome/check-kernel.sh $KERNEL_TREE/.config"
echo "Then rebuild the custom Spectre kernel."
