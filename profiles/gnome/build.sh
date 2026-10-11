#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KERNEL_TREE="${1:-${SPECTRE_KERNEL_TREE:-$HOME/linux-7.1.8}}"

for pkgcmd in debootstrap mkfs.ext4 qemu-system-x86_64; do
    if ! command -v "$pkgcmd" >/dev/null 2>&1; then
        echo "Missing host command: $pkgcmd" >&2
        echo "On Linux Mint/Ubuntu install: sudo apt install debootstrap e2fsprogs qemu-system-x86" >&2
        exit 1
    fi
done

"$ROOT/profiles/gnome/create-rootfs.sh"

if [[ -f "$KERNEL_TREE/arch/x86/boot/bzImage" ]]; then
    "$ROOT/profiles/gnome/install-kernel.sh" "$KERNEL_TREE"
else
    echo "[Spectre] Custom kernel was not found at $KERNEL_TREE; creating legacy rootfs image only." >&2
fi

"$ROOT/profiles/gnome/verify.sh"
"$ROOT/profiles/gnome/make-disk-image.sh"

echo
echo "[ok] Spectre GNOME rootfs image is ready."
echo "Direct-kernel development boot:"
echo "  ./profiles/gnome/run-qemu.sh $KERNEL_TREE/arch/x86/boot/bzImage"
echo
echo "For a normal UEFI/GRUB bootable disk image run:"
echo "  ./profiles/gnome/build-uefi.sh $KERNEL_TREE"
