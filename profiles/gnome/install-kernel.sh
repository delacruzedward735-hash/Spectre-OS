#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TARGET="${SPECTRE_GNOME_ROOTFS:-$ROOT/rootfs-gnome}"
KERNEL_TREE="${1:-$HOME/linux-7.1.8}"

[[ -d "$TARGET/etc" ]] || { echo "GNOME rootfs not found: $TARGET" >&2; exit 1; }
[[ -f "$KERNEL_TREE/arch/x86/boot/bzImage" ]] || { echo "Built kernel not found in: $KERNEL_TREE" >&2; exit 1; }
[[ -f "$KERNEL_TREE/.config" ]] || { echo "Kernel .config not found in: $KERNEL_TREE" >&2; exit 1; }

KREL="$(make -s -C "$KERNEL_TREE" kernelrelease)"

echo "[Spectre] Installing kernel $KREL into GNOME rootfs..."
if grep -q '^CONFIG_MODULES=y' "$KERNEL_TREE/.config"; then
    sudo make -C "$KERNEL_TREE" modules_install INSTALL_MOD_PATH="$TARGET" INSTALL_MOD_STRIP=1
else
    echo "[Spectre] CONFIG_MODULES is disabled; skipping modules_install."
fi

sudo install -d "$TARGET/boot"
sudo install -m 0644 "$KERNEL_TREE/arch/x86/boot/bzImage" "$TARGET/boot/vmlinuz-$KREL"
sudo install -m 0644 "$KERNEL_TREE/.config" "$TARGET/boot/config-$KREL"
[[ -f "$KERNEL_TREE/System.map" ]] && sudo install -m 0644 "$KERNEL_TREE/System.map" "$TARGET/boot/System.map-$KREL"
sudo ln -sfn "vmlinuz-$KREL" "$TARGET/boot/vmlinuz-spectre"

if [[ -x "$TARGET/usr/sbin/depmod" ]]; then
    sudo chroot "$TARGET" depmod "$KREL" || true
fi

if [[ -x "$TARGET/usr/sbin/plymouth-set-default-theme" && -f "$TARGET/usr/share/plymouth/themes/spectre/spectre.plymouth" ]]; then
    echo "[Spectre] Selecting Spectre animated Plymouth theme..."
    sudo chroot "$TARGET" plymouth-set-default-theme spectre || true
fi

if [[ -x "$TARGET/usr/sbin/update-initramfs" ]]; then
    echo "[Spectre] Building matching initramfs with Spectre boot branding..."
    sudo chroot "$TARGET" update-initramfs -c -k "$KREL"
    if [[ -f "$TARGET/boot/initrd.img-$KREL" ]]; then
        sudo ln -sfn "initrd.img-$KREL" "$TARGET/boot/initrd-spectre.img"
    fi
else
    echo "[Spectre] update-initramfs not found; UEFI image creation will require an initramfs." >&2
fi

cat <<EOF2 | sudo tee "$TARGET/etc/spectre-kernel" >/dev/null
KERNEL_RELEASE=$KREL
KERNEL_IMAGE=/boot/vmlinuz-$KREL
INITRD_IMAGE=/boot/initrd.img-$KREL
EOF2

echo "[ok] Custom Spectre kernel installed in $TARGET/boot"
echo "     Kernel release: $KREL"
