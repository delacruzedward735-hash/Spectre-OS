#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TARGET="${SPECTRE_GNOME_ROOTFS:-$ROOT/rootfs-gnome}"
BRANDING="$ROOT/profiles/gnome/branding"
SPECTRE_USER="${SPECTRE_USER:-spectre}"

[[ -d "$TARGET/etc" ]] || { echo "GNOME rootfs not found: $TARGET" >&2; exit 1; }
[[ -f "$BRANDING/plymouth/spectre/spectre.plymouth" ]] || { echo "Spectre Plymouth assets missing." >&2; exit 1; }

printf '[Spectre] Installing boot animation and login logo...\n'

sudo install -d \
    "$TARGET/usr/share/plymouth/themes/spectre" \
    "$TARGET/usr/share/pixmaps" \
    "$TARGET/var/lib/AccountsService/icons" \
    "$TARGET/var/lib/AccountsService/users"

sudo rm -rf "$TARGET/usr/share/plymouth/themes/spectre"
sudo install -d "$TARGET/usr/share/plymouth/themes/spectre"
sudo cp -a "$BRANDING/plymouth/spectre/." "$TARGET/usr/share/plymouth/themes/spectre/"

sudo install -m 0644 "$BRANDING/pixmaps/spectre-logo.png" \
    "$TARGET/usr/share/pixmaps/spectre-logo.png"
sudo install -m 0644 "$BRANDING/pixmaps/spectre-avatar.png" \
    "$TARGET/usr/share/pixmaps/spectre-avatar.png"

if [[ -d "$TARGET/home/$SPECTRE_USER" ]]; then
    sudo install -m 0644 "$BRANDING/pixmaps/spectre-avatar.png" \
        "$TARGET/var/lib/AccountsService/icons/$SPECTRE_USER"
    cat <<EOF2 | sudo tee "$TARGET/var/lib/AccountsService/users/$SPECTRE_USER" >/dev/null
[User]
Icon=/var/lib/AccountsService/icons/$SPECTRE_USER
SystemAccount=false
EOF2
fi

if [[ -x "$TARGET/usr/sbin/plymouth-set-default-theme" ]]; then
    sudo chroot "$TARGET" plymouth-set-default-theme spectre
else
    echo "[WARN] plymouth-set-default-theme is missing inside the rootfs." >&2
    echo "       Install plymouth and plymouth-themes, then run this script again." >&2
fi

if compgen -G "$TARGET/boot/initrd.img-*" >/dev/null && [[ -x "$TARGET/usr/sbin/update-initramfs" ]]; then
    printf '[Spectre] Rebuilding initramfs with Spectre boot branding...\n'
    sudo chroot "$TARGET" update-initramfs -u -k all
fi

echo '[ok] Spectre boot branding installed.'
