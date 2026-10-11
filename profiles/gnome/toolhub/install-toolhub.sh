#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
PAYLOAD="$ROOT/profiles/gnome/toolhub/app"
TARGET="${SPECTRE_GNOME_ROOTFS:-${1:-}}"

[[ -n "$TARGET" ]] || { echo '[ToolHub][FAIL] SPECTRE_GNOME_ROOTFS/target root is required.' >&2; exit 2; }
TARGET="$(readlink -m "$TARGET")"
[[ -d "$TARGET" ]] || { echo "[ToolHub][FAIL] Target root missing: $TARGET" >&2; exit 2; }
[[ -d "$PAYLOAD/toolhub" ]] || { echo "[ToolHub][FAIL] Payload missing: $PAYLOAD/toolhub" >&2; exit 2; }

APPDIR="$TARGET/usr/lib/spectre-toolhub"
BINDIR="$TARGET/usr/local/bin"
DESKTOPDIR="$TARGET/usr/share/applications"
ICONROOT="$TARGET/usr/share/icons/hicolor"
SHAREDIR="$TARGET/usr/share/spectre-toolhub"

sudo rm -rf --one-file-system -- "$APPDIR"
sudo install -d -m 0755 "$APPDIR" "$BINDIR" "$DESKTOPDIR" "$SHAREDIR"
sudo cp -a "$PAYLOAD/toolhub" "$APPDIR/toolhub"
sudo install -m 0644 "$PAYLOAD/pyproject.toml" "$APPDIR/pyproject.toml"
sudo install -m 0755 "$PAYLOAD/system-launcher.sh" "$BINDIR/spectre-toolhub"
sudo install -m 0644 "$PAYLOAD/com.spectre.ToolHub.desktop" "$DESKTOPDIR/com.spectre.ToolHub.desktop"
sudo install -m 0644 "$PAYLOAD/icons/spectre-toolhub-brand.png" "$SHAREDIR/spectre-toolhub-brand.png"

for size in 48 64 128 256 512; do
    dir="$ICONROOT/${size}x${size}/apps"
    sudo install -d -m 0755 "$dir"
    sudo install -m 0644 "$PAYLOAD/icons/spectre-toolhub-${size}.png" "$dir/spectre-toolhub.png"
done

sudo chown -R root:root "$APPDIR" "$SHAREDIR" "$DESKTOPDIR/com.spectre.ToolHub.desktop" "$BINDIR/spectre-toolhub"
sudo find "$APPDIR" -type d -exec chmod 0755 {} +
sudo find "$APPDIR" -type f -exec chmod 0644 {} +
sudo chmod 0755 "$BINDIR/spectre-toolhub"

# Remove developer/test debris if a payload source tree ever contains it.
sudo find "$APPDIR" -depth \( -type d -name '__pycache__' -o -type f \( -name '*.pyc' -o -name '*.pyo' \) \) -exec rm -rf {} + 2>/dev/null || true

# Menu/icon caches are best-effort; GNOME also discovers entries without them.
if [[ -x "$TARGET/usr/bin/update-desktop-database" ]]; then
    sudo chroot "$TARGET" update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
fi
if [[ -x "$TARGET/usr/bin/gtk-update-icon-cache" ]]; then
    sudo chroot "$TARGET" gtk-update-icon-cache -f -t /usr/share/icons/hicolor >/dev/null 2>&1 || true
elif [[ -x "$TARGET/usr/bin/gtk4-update-icon-cache" ]]; then
    sudo chroot "$TARGET" gtk4-update-icon-cache -f -t /usr/share/icons/hicolor >/dev/null 2>&1 || true
fi

echo '[ToolHub][OK] Spectre ToolHub installed into target root.'
