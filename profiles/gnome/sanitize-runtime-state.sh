#!/usr/bin/env bash
set -euo pipefail
TARGET="${1:-}"
[[ -n "$TARGET" ]] || { echo "usage: $0 /path/to/rootfs" >&2; exit 2; }
TARGET="$(readlink -f "$TARGET")"
[[ "$TARGET" != "/" && -d "$TARGET/etc" && -d "$TARGET/usr" ]] || {
  echo "[FAIL] refusing unsafe runtime target: $TARGET" >&2; exit 2;
}

# Build templates must never publish mutable GNOME/QEMU state from a previous
# engineering session. Keep documents and application data intact; remove only
# generated session/configuration state that must be recreated on first login.
if [[ -d "$TARGET/home/spectre" ]]; then
  sudo rm -f "$TARGET/home/spectre/.config/dconf/user"
  sudo rm -f "$TARGET/home/spectre/.config/monitors.xml"
  sudo rm -rf "$TARGET/home/spectre/.cache/gnome-shell"
  sudo rm -rf "$TARGET/home/spectre/.local/share/gnome-shell/extensions/spectre-panel@spectre.os"
  sudo rm -rf "$TARGET/home/spectre/.local/share/gnome-shell/extensions/spectre-hud@spectre.os"
  sudo rm -rf "$TARGET/home/spectre/.local/share/gnome-shell/extensions/spectre-desktop-menu@spectre.os"
  sudo rm -rf "$TARGET/home/spectre/.local/share/gnome-shell/extensions/spectre-desktop-ux@spectre.os"
  sudo rm -f "$TARGET/home/spectre/.config/spectre/theme-"*-applied
  sudo rm -rf "$TARGET/home/spectre/.config/conky"
  sudo rm -f "$TARGET/home/spectre/.config/autostart/"*conky*.desktop 2>/dev/null || true
fi

sudo install -d -m 0755 "$TARGET/run" "$TARGET/run/lock"
sudo install -d -m 1777 "$TARGET/tmp" "$TARGET/var/tmp"
sudo chmod 0755 "$TARGET/run" "$TARGET/run/lock"
sudo chmod 1777 "$TARGET/tmp" "$TARGET/var/tmp"

# Every clone/live boot receives a fresh machine identity.
sudo rm -f "$TARGET/var/lib/dbus/machine-id"
if [[ -e "$TARGET/etc/machine-id" ]]; then
  sudo truncate -s 0 "$TARGET/etc/machine-id"
else
  sudo touch "$TARGET/etc/machine-id"
fi

echo '[ok] Mutable GNOME/QEMU runtime state sanitized.'
