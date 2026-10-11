#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/config/release.conf"
TARGET="${SPECTRE_GNOME_ROOTFS:-$ROOT/rootfs-gnome}"

checks=(
  /etc/os-release
  /etc/fstab
  /etc/modprobe.d/spectre-quiet.conf
  /run
  /usr/bin/gnome-shell
  /usr/sbin/gdm3
  /usr/bin/nautilus
  /usr/local/bin/spectre-gnome-style
  /usr/local/bin/spectre-welcome
  /usr/local/bin/spectre-center
  /usr/local/bin/spectre-shell-health
  /usr/local/bin/spectre-taskbar-settings
  /usr/local/bin/spectre-desktop-refresh
  /usr/local/bin/spectre-diagnostics
  /usr/local/sbin/spectre-update
  /usr/local/sbin/spectre-healthcheck
  /etc/systemd/system/spectre-healthcheck.service
  /usr/share/applications/com.spectre.Welcome.desktop
  /usr/share/applications/com.spectre.Center.desktop
  /usr/share/applications/com.spectre.TaskbarSettings.desktop
  /usr/share/backgrounds/spectre/spectre-gnome.png
  /usr/share/themes/Spectre-Night/gnome-shell/gnome-shell.css
  /usr/share/gnome-shell/extensions/spectre-panel@spectre.os/extension.js
  /usr/share/gnome-shell/extensions/spectre-hud@spectre.os/extension.js
  /usr/share/gnome-shell/extensions/spectre-desktop-menu@spectre.os/extension.js
  /usr/share/glib-2.0/schemas/org.spectre.desktop.gschema.xml
  /usr/share/pixmaps/spectre-logo.png
)

failed=0
for path in "${checks[@]}"; do
    if [[ -e "$TARGET$path" ]]; then
        printf '[OK]   %s\n' "$path"
    else
        printf '[MISS] %s\n' "$path"
        failed=1
    fi
done

if [[ -d "$TARGET/boot" ]]; then
    kernel="$(find "$TARGET/boot" -maxdepth 1 -type f -name 'vmlinuz-*' | sort | tail -1 || true)"
    if [[ -n "$kernel" ]]; then
        krel="${kernel##*/vmlinuz-}"
        printf '[OK]   /boot/vmlinuz-%s\n' "$krel"
        if [[ -f "$TARGET/boot/initrd.img-$krel" ]]; then
            printf '[OK]   /boot/initrd.img-%s\n' "$krel"
        else
            printf '[WARN] kernel exists but matching initramfs is missing\n'
        fi
    else
        printf '[INFO] custom kernel not installed into GNOME rootfs yet\n'
    fi
fi

if [[ "$failed" -ne 0 ]]; then
    echo "Spectre GNOME rootfs verification failed." >&2
    exit 1
fi

grep -q '^ID=spectre$' "$TARGET/etc/os-release" || {
    echo "Spectre identity missing from /etc/os-release" >&2
    exit 1
}

grep -Fqx "PRETTY_NAME=\"$SPECTRE_PRETTY_NAME\"" "$TARGET/etc/os-release" || {
    echo "Spectre release identity does not match config/release.conf" >&2
    exit 1
}

"$ROOT/profiles/gnome/verify-product-boundaries.sh" "$TARGET"

if find "$TARGET" -xdev -iname '*conky*' -print -quit 2>/dev/null | grep -q .; then
    echo "Legacy Conky files remain in the GNOME rootfs" >&2
    exit 1
fi

mode_run="$(stat -c '%a' "$TARGET/run" 2>/dev/null || true)"
[[ "$mode_run" == "755" ]] || {
    echo "Spectre rootfs /run mount point is missing or has wrong mode ($mode_run)" >&2
    exit 1
}

networking_mask="$(readlink "$TARGET/etc/systemd/system/networking.service" 2>/dev/null || true)"
[[ "$networking_mask" == "/dev/null" ]] || {
    echo "Legacy networking.service is not masked ($networking_mask)" >&2
    exit 1
}
printf '[OK]   networking.service masked; NetworkManager is the sole owner\n'

for desktop_id in \
    org.gnome.Nautilus.desktop \
    org.gnome.Terminal.desktop \
    firefox-esr.desktop \
    com.spectre.Center.desktop \
    org.gnome.Settings.desktop; do
    [[ -f "$TARGET/usr/share/applications/$desktop_id" ]] || {
        echo "Required app-grid launcher is missing: $desktop_id" >&2
        exit 1
    }
    if grep -Eqi '^NoDisplay=(true|1|yes)$' "$TARGET/usr/share/applications/$desktop_id"; then
        echo "Required app-grid launcher is hidden: $desktop_id" >&2
        exit 1
    fi
    printf '[OK]   app-grid launcher: %s\n' "$desktop_id"
done

visible_launcher_count="$(python3 - "$TARGET" <<'PY'
import configparser
from pathlib import Path
import sys

root = Path(sys.argv[1]) / 'usr/share/applications'
visible = set()
for desktop in root.glob('*.desktop'):
    parser = configparser.ConfigParser(interpolation=None, strict=False)
    parser.optionxform = str
    try:
        parser.read(desktop, encoding='utf-8')
        entry = parser['Desktop Entry']
    except Exception:
        continue
    truthy = lambda value: str(value).strip().lower() in {'1', 'true', 'yes'}
    if entry.get('Type') != 'Application':
        continue
    if truthy(entry.get('Hidden', 'false')) or truthy(entry.get('NoDisplay', 'false')):
        continue
    visible.add(desktop.name)
print(len(visible))
PY
)"
if ((visible_launcher_count < 8)); then
    echo "Too few visible application launchers for a usable grid: $visible_launcher_count" >&2
    exit 1
fi
printf '[OK]   %s visible application launchers available to GNOME\n' "$visible_launcher_count"

echo "[ok] Spectre GNOME rootfs foundation is present."

# BEGIN SPECTRE-1.0-RESTORE-INSTALLER-LIGHT-WALLPAPERS
for _f in   usr/local/bin/spectre-live-installer-setup   usr/local/bin/spectre-installer-launcher   usr/local/sbin/spectre-installer   usr/local/sbin/spectre-installer-backend   usr/share/applications/com.spectre.Installer.desktop   usr/share/pixmaps/spectre-installer.png   etc/xdg/autostart/spectre-live-installer.desktop   etc/polkit-1/rules.d/49-spectre-installer.rules   usr/share/themes/Spectre-Day/gnome-shell/gnome-shell.css   usr/local/bin/spectre-appearance-sync   etc/xdg/autostart/spectre-appearance-sync.desktop   usr/share/gnome-background-properties/spectre.xml   usr/share/backgrounds/spectre/collection/spectre-default-dark.png   usr/share/backgrounds/spectre/collection/spectre-default-light.png
do
  [[ -e "$TARGET/$_f" ]] || { echo "[FAIL] missing restored release component: /$_f" >&2; exit 1; }
  echo "[OK]   /$_f"
done
echo "[ok] installer/light-mode/wallpaper restore verification passed."
# END SPECTRE-1.0-RESTORE-INSTALLER-LIGHT-WALLPAPERS

# BEGIN SPECTRE-1.0-LIVE-INSTALLER-VISIBILITY-v1.1
_INSTALLER_DESKTOP="$TARGET/usr/share/applications/com.spectre.Installer.desktop"
[[ -f "$_INSTALLER_DESKTOP" ]] || { echo "[FAIL] visible installer desktop entry missing" >&2; exit 1; }
grep -Fq 'Name=Install Spectre OS' "$_INSTALLER_DESKTOP" || { echo "[FAIL] installer launcher name missing" >&2; exit 1; }
grep -Fq 'Exec=/usr/local/bin/spectre-installer-launcher' "$_INSTALLER_DESKTOP" || { echo "[FAIL] installer launcher Exec is wrong" >&2; exit 1; }
if grep -Eq '^(NoDisplay|Hidden)=true$' "$_INSTALLER_DESKTOP"; then
  echo "[FAIL] installer launcher is hidden from GNOME app grid" >&2
  exit 1
fi
[[ -x "$TARGET/usr/local/bin/spectre-live-installer-shortcut-setup" ]] || { echo "[FAIL] live installer shortcut helper missing" >&2; exit 1; }
[[ -f "$TARGET/etc/xdg/autostart/spectre-live-installer-shortcut.desktop" ]] || { echo "[FAIL] live installer shortcut autostart missing" >&2; exit 1; }
[[ -f "$TARGET/etc/skel/Desktop/Install Spectre OS.desktop" ]] || { echo "[FAIL] installer desktop seed missing" >&2; exit 1; }
echo "[OK]   installer is visible in GNOME application grid"
echo "[OK]   live desktop installer shortcut is staged"
# END SPECTRE-1.0-LIVE-INSTALLER-VISIBILITY-v1.1
