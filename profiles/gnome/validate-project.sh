#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/config/release.conf"

echo '[Spectre] Checking shell syntax...'
source_scan_roots=(
    "$ROOT/profiles"
    "$ROOT/scripts"
    "$ROOT/rootfs"
)
find "${source_scan_roots[@]}" -type f \( \
    -name '*.sh' -o -name 'spectre-diagnostics' -o -name 'spectre-update' -o \
    -name 'spectre-healthcheck' -o -name 'spectre-installer' -o \
    -name 'spectrectl' -o -name 'spectre-net' -o -name 'init' \
    \) -print0 | sort -z |
while IFS= read -r -d '' script; do
    first_line="$(head -n1 "$script" 2>/dev/null || true)"
    case "$first_line" in
        '#!/usr/bin/env bash'|'#!/bin/bash'|'#!/bin/sh'|'#!/usr/bin/env sh')
            bash -n "$script"
            printf '[OK] %s\n' "${script#$ROOT/}"
            ;;
    esac
done

echo '[Spectre] Checking Python helper syntax without creating bytecode...'
for helper in spectre-welcome spectre-center spectre-taskbar-settings spectre-desktop-apps spectre-run spectre-power-menu spectre-shortcuts spectre-clipboard spectre-update-manager; do
    file="$ROOT/profiles/gnome/branding/bin/$helper"
    python3 -c 'import pathlib, sys; p=pathlib.Path(sys.argv[1]); compile(p.read_text(), str(p), "exec")' "$file"
    printf '[OK] %s\n' "${file#$ROOT/}"
done

if command -v node >/dev/null 2>&1; then
    for extension in spectre-panel@spectre.os spectre-hud@spectre.os spectre-desktop-menu@spectre.os; do
        node --input-type=module --check < "$ROOT/profiles/gnome/branding/extensions/$extension/extension.js"
        printf '[OK] %s\n' "profiles/gnome/branding/extensions/$extension/extension.js"
    done
else
    printf '[INFO] node not installed; skipped JavaScript parser check\n'
fi

echo '[Spectre] Checking JSON, XML and desktop-entry structure...'
python3 - "$ROOT" <<'PY'
import configparser
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

root = Path(sys.argv[1])
for metadata in root.glob('profiles/gnome/branding/extensions/*/metadata.json'):
    data = json.loads(metadata.read_text())
    for key in ('uuid', 'name', 'shell-version'):
        if key not in data:
            raise SystemExit(f'{metadata}: missing {key}')

ET.parse(root / 'profiles/gnome/branding/schemas/org.spectre.desktop.gschema.xml')

desktop_files = list(root.glob('profiles/gnome/**/*.desktop'))
for desktop in desktop_files:
    parser = configparser.ConfigParser(interpolation=None, strict=False)
    parser.optionxform = str
    parser.read(desktop)
    if 'Desktop Entry' not in parser:
        raise SystemExit(f'{desktop}: missing [Desktop Entry]')
    entry = parser['Desktop Entry']
    for key in ('Type', 'Name'):
        if not entry.get(key):
            raise SystemExit(f'{desktop}: missing {key}')
    if entry.get('Type') == 'Application' and not entry.get('Exec'):
        raise SystemExit(f'{desktop}: application missing Exec')
print(f'[OK] parsed {len(desktop_files)} desktop entries')
PY

[[ "$(<"$ROOT/VERSION")" == "$SPECTRE_VERSION_TAG" ]] || {
    echo '[FAIL] VERSION and config/release.conf disagree' >&2
    exit 1
}
printf '[OK] release identity: %s\n' "$SPECTRE_PRETTY_NAME"

required=(
  config/release.conf
  profiles/gnome/branding/backgrounds/spectre-gnome.png
  profiles/gnome/branding/themes/Spectre-Night/gnome-shell/gnome-shell.css
  profiles/gnome/branding/themes/Spectre-Day/gnome-shell/gnome-shell.css
  profiles/gnome/branding/backgrounds/spectre.xml
  profiles/gnome/branding/backgrounds/collection/spectre-default-dark.png
  profiles/gnome/branding/backgrounds/collection/spectre-default-light.png
  profiles/gnome/branding/pixmaps/spectre-logo.png
  profiles/gnome/branding/pixmaps/spectre-avatar.png
  profiles/gnome/branding/plymouth/spectre/spectre.plymouth
  profiles/gnome/branding/plymouth/spectre/spectre.script
  profiles/gnome/branding/plymouth/spectre/spectre-icon.png
  profiles/gnome/branding/plymouth/spectre/dot.png
  profiles/gnome/branding/plymouth/spectre/spectre-wordmark.png
  profiles/gnome/branding/extensions/spectre-panel@spectre.os/metadata.json
  profiles/gnome/branding/extensions/spectre-hud@spectre.os/metadata.json
  profiles/gnome/branding/extensions/spectre-desktop-menu@spectre.os/metadata.json
  profiles/gnome/branding/schemas/org.spectre.desktop.gschema.xml
  profiles/gnome/branding/applications/com.spectre.Center.desktop
  profiles/gnome/branding/applications/com.spectre.TaskbarSettings.desktop
  profiles/gnome/branding/applications/com.spectre.DesktopApps.desktop
  profiles/gnome/branding/applications/com.spectre.Shortcuts.desktop
  profiles/gnome/branding/applications/com.spectre.UpdateManager.desktop
  profiles/gnome/branding/bin/spectre-taskbar-settings
  profiles/gnome/branding/bin/spectre-desktop-refresh
  profiles/gnome/branding/bin/spectre-appearance-sync
  profiles/gnome/branding/bin/spectre-desktop-apps
  profiles/gnome/branding/bin/spectre-run
  profiles/gnome/branding/bin/spectre-power-menu
  profiles/gnome/branding/bin/spectre-files
  profiles/gnome/branding/bin/spectre-shortcut-defaults
  profiles/gnome/branding/bin/spectre-shortcuts
  profiles/gnome/branding/bin/spectre-clipboard
  profiles/gnome/branding/bin/spectre-update-manager
  profiles/gnome/branding/bin/spectre-hardware
  profiles/gnome/branding/bin/spectre-hardware-qualification
  profiles/gnome/branding/bin/spectre-suspend-qualification
  profiles/gnome/branding/bin/spectre-recovery
  profiles/gnome/branding/bin/spectre-patch-ding
  profiles/gnome/branding/system/grub.d/42_spectre_recovery
  profiles/gnome/branding/bin/spectre-installed-health
  profiles/gnome/branding/bin/spectre-installed-qualification
  profiles/gnome/branding/bin/spectre-status
  profiles/gnome/branding/bin/spectre-support-report
  profiles/gnome/branding/bin/spectre-qualification
  profiles/gnome/branding/bin/spectre-maintenance
  profiles/gnome/branding/bin/spectre-installed-sanitize
  profiles/gnome/branding/bin/spectre-boot-record
  profiles/gnome/branding/systemd/spectre-boot-record.service
  profiles/gnome/branding/systemd/spectre-maintenance.service
  profiles/gnome/branding/systemd/spectre-maintenance.timer
  profiles/gnome/branding/systemd/spectre-installed-sanitize.service
  profiles/gnome/branding/system/journald-spectre.conf
  profiles/gnome/branding/system/zram-generator.conf
  profiles/gnome/quick-check.sh
  profiles/gnome/installer/spectre-live-installer-setup
  profiles/gnome/installer/spectre-installer-launcher
  profiles/gnome/installer/assets/spectre-installer.png
  profiles/gnome/installer/icons/48x48/apps/spectre-installer.png
  profiles/gnome/installer/icons/64x64/apps/spectre-installer.png
  profiles/gnome/installer/icons/128x128/apps/spectre-installer.png
  profiles/gnome/installer/icons/256x256/apps/spectre-installer.png
  profiles/gnome/installer/icons/512x512/apps/spectre-installer.png
  profiles/gnome/installer/spectre-live-installer.desktop
  profiles/gnome/personal-apps/registry.tsv
  profiles/gnome/personal-apps/managed_app.py
  profiles/gnome/personal-apps/validate-managed-apps.sh
  profiles/gnome/personal-apps/install-managed-apps.sh
  tools/spectre-add-app
  tools/spectre-list-apps
  tools/spectre-remove-app
  profiles/gnome/reset-qemu-install-test.sh
  profiles/gnome/clean-product-rootfs.sh
  profiles/gnome/verify-product-boundaries.sh
  profiles/gnome/runtime-source-hash.sh
  profiles/gnome/sanitize-runtime-state.sh
  profiles/gnome/sync-runtime-root.sh
  profiles/gnome/make-uefi-disk-image.sh
  profiles/gnome/run-qemu-uefi.sh
  profiles/gnome/run-qemu-installed.sh
  profiles/gnome/freeze-qemu-installed-baseline.sh
  profiles/gnome/run-qemu-iso-bios.sh
  profiles/gnome/run-qemu-installed-bios.sh
  tests/test-runtime-source-sync.sh
  tests/test-installer-rc2.sh
  tests/test-installer-rc4.sh
  tests/test-rc42-ux.sh
  tests/test-rc56-runtime-ui-installer.sh
  tests/test-rc561-desktop-menu-insight.sh
  tests/test-rc562-desktop-provider.sh
  tests/test-rc6-physical-boot-health-apps.sh
  tests/test-v1-production-release.sh
  tests/test-v1-app-framework.sh
  tests/test-v1-windows-shortcuts.sh
  tests/test-v1-files-launcher.sh
  tests/test-v1-core-only-release.sh
)
for rel in "${required[@]}"; do
    [[ -e "$ROOT/$rel" ]] || { echo "[MISS] $rel" >&2; exit 1; }
    printf '[OK] %s\n' "$rel"
done

debris="$(
    find "$ROOT" \
        \( -path "$ROOT/rootfs-gnome" -o -path "$ROOT/iso" -o \
           -path "$ROOT/build" -o -path "$ROOT/.git" \) -prune -o \
        -type f \( -name '*.pyc' -o -name 'wget-log*' -o \
            -name '*.backup' -o -name '*.backup*' -o -name '*.before-*' \) \
        -print -quit
)"
[[ -z "$debris" ]] || {
    echo "[FAIL] development debris remains: ${debris#$ROOT/}" >&2
    exit 1
}
printf '[OK] source archive contains no generated backup/log/bytecode debris\n'

if grep -qs 'pgrep -x qemu-system-x86_64' \
    "$ROOT/profiles/gnome/build-live-iso.sh" \
    "$ROOT/profiles/gnome/release-check.sh"; then
    echo '[FAIL] long QEMU process name is checked with ineffective pgrep -x' >&2
    exit 1
fi
printf '[OK] QEMU process checks use full command-line matching\n'

if grep -Eqs 'gset[[:space:]]+org[.]gnome[.]shell[[:space:]]+app-picker-layout[[:space:]]+"?\[\]"?' \
    "$ROOT/profiles/gnome/branding/spectre-gnome-style.sh"; then
    echo '[FAIL] explicit empty app-picker layout can blank the GNOME app grid' >&2
    exit 1
fi
panel_extension="$ROOT/profiles/gnome/branding/extensions/spectre-panel@spectre.os/extension.js"
schema="$ROOT/profiles/gnome/branding/schemas/org.spectre.desktop.gschema.xml"
if grep -q "set_value('app-picker-layout'" "$panel_extension"; then
    echo '[FAIL] Spectre Panel still writes GNOME Shell private app-picker layout data' >&2
    exit 1
fi
grep -q "reset('app-picker-layout'" "$panel_extension" || {
    echo '[FAIL] Spectre Panel does not reset stale app-picker state to GNOME defaults' >&2
    exit 1
}
grep -q 'name="app-grid-initialized"' "$schema" || {
    echo '[FAIL] application-grid initialization state is missing from the Spectre schema' >&2
    exit 1
}
if grep -Eq '_appDisplay|_orderedItems|OverviewControls|_overview[^[:alnum:]_]*\?*\._controls' "$panel_extension"; then
    echo '[FAIL] Spectre Panel still manipulates GNOME private app-grid actors' >&2
    exit 1
fi
printf '[OK] GNOME app picker uses one-time Shell-managed reset with no private actor manipulation\n'

hud_extension="$ROOT/profiles/gnome/branding/extensions/spectre-hud@spectre.os/extension.js"
grep -q 'spectre-settings-toggle' "$hud_extension" || {
    echo '[FAIL] top-panel Settings shortcut is missing' >&2
    exit 1
}
grep -q "PopupSwitchMenuItem" "$hud_extension" || {
    echo '[FAIL] Spectre Insight does not expose its desktop-card switch' >&2
    exit 1
}
grep -q '_safeUpdateMetrics()' "$hud_extension" || {
    echo '[FAIL] Spectre Insight timer is not protected against transient Shell actor errors' >&2
    exit 1
}
grep -q 'Main.layoutManager.addChrome' "$hud_extension" || {
    echo '[FAIL] Spectre Insight desktop cards are not registered through LayoutManager chrome' >&2
    exit 1
}
if grep -q 'Main[.]layoutManager[.]_backgroundGroup' "$hud_extension"; then
    echo '[FAIL] Spectre Insight still depends on GNOME private _backgroundGroup' >&2
    exit 1
fi
grep -q '_currentWorkspaceHasWindow' "$hud_extension" || {
    echo '[FAIL] Spectre Insight does not hide desktop cards behind normal windows' >&2
    exit 1
}
printf '[OK] Spectre Insight degrades safely and uses managed chrome instead of private background actors\n'

grep -q 'install -d -m 0755 "$STAGE/run"' "$ROOT/profiles/gnome/build-live-iso.sh" || {
    echo '[FAIL] live image builder does not create the /run mount point' >&2
    exit 1
}
grep -q '"$TARGET/run"' "$ROOT/profiles/gnome/installer/spectre-installer-backend" || {
    echo '[FAIL] installer backend does not prepare the target /run mount point' >&2
    exit 1
}
printf '[OK] live and installed roots prepare /run before boot/chroot mounts\n'


installer="$ROOT/profiles/gnome/installer/spectre-installer"
backend="$ROOT/profiles/gnome/installer/spectre-installer-backend"
desktop_entry="$ROOT/profiles/gnome/installer/com.spectre.Installer.desktop"
launcher="$ROOT/profiles/gnome/installer/spectre-installer-launcher"

python3 - "$installer" <<'PYCODE' || { echo '[FAIL] GTK installer frontend does not parse as Python' >&2; exit 1; }
import pathlib,sys
compile(pathlib.Path(sys.argv[1]).read_text(), sys.argv[1], 'exec')
PYCODE
bash -n "$backend" "$launcher" || { echo '[FAIL] installer backend/launcher shell syntax failed' >&2; exit 1; }
responsive_installer="$ROOT/profiles/gnome/installer/spectre-installer"
grep -Fq 'self.win.set_resizable(True)' "$responsive_installer" || { echo '[FAIL] responsive installer resizable contract missing' >&2; exit 1; }
grep -Fq 'self.win.set_default_size(1000, 640)' "$responsive_installer" || { echo '[FAIL] responsive installer default size missing' >&2; exit 1; }
grep -Fq 'self.win.set_size_request(760, 500)' "$responsive_installer" || { echo '[FAIL] responsive installer minimum size missing' >&2; exit 1; }
grep -Fq 'self.page_scroll = Gtk.ScrolledWindow()' "$responsive_installer" || { echo '[FAIL] responsive installer page scroller missing' >&2; exit 1; }
grep -Fq 'self.page_scroll.set_child(self.stack)' "$responsive_installer" || { echo '[FAIL] responsive installer stack scrolling contract missing' >&2; exit 1; }
for page in 'Welcome to Spectre OS' 'Keyboard layout' 'Installation type' 'Where are you?' 'Who are you?' 'Ready to install' 'Installing Spectre OS'; do
    grep -Fq "$page" "$installer" || { echo "[FAIL] installer wizard page missing: $page" >&2; exit 1; }
done
grep -q 'Install Spectre OS alongside Windows' "$installer" || { echo '[FAIL] alongside-Windows installer option missing' >&2; exit 1; }
grep -q 'MIN_ALONGSIDE_FREE' "$installer" || { echo '[FAIL] frontend lacks safe unallocated-space gate for alongside mode' >&2; exit 1; }
grep -q 'pkexec.*spectre-installer-backend' "$installer" || { echo '[FAIL] GTK frontend does not isolate privilege to the install backend' >&2; exit 1; }

grep -q 'MIN_DISK_BYTES=.*32' "$backend" || { echo '[FAIL] backend lacks the 32 GiB minimum-disk gate' >&2; exit 1; }
grep -q 'LIVE_DISK' "$backend" || { echo '[FAIL] backend does not protect the live-media parent disk' >&2; exit 1; }
grep -Fq '[[ "$CONFIRMATION" == "ERASE" ]]' "$backend" || { echo '[FAIL] backend lacks erase safety-word confirmation' >&2; exit 1; }
grep -Fq '[[ "$CONFIRMATION" == "INSTALL" ]]' "$backend" || { echo '[FAIL] backend lacks alongside safety-word confirmation' >&2; exit 1; }
grep -Fq '[[ "$ACKNOWLEDGED" == "1" ]]' "$backend" || { echo '[FAIL] backend lacks explicit destructive-operation acknowledgement' >&2; exit 1; }
grep -q 'mount -t tmpfs.*"\$TARGET/run"' "$backend" || { echo '[FAIL] target chroot /run is not isolated from the live session' >&2; exit 1; }
if grep -qE 'mount[[:space:]]+--bind[[:space:]]+/run[[:space:]]+"?\$TARGET/run' "$backend"; then
    echo '[FAIL] installer still bind-mounts live /run into the target chroot' >&2; exit 1
fi
grep -q 'EFI/Microsoft/Boot/bootmgfw.efi' "$backend" || { echo '[FAIL] alongside mode does not verify Windows Boot Manager' >&2; exit 1; }
grep -q 'WINDOWS_EFI_HASH' "$backend" || { echo '[FAIL] alongside mode does not preserve-check the Windows EFI loader' >&2; exit 1; }
grep -q '36 GiB' "$backend" || { echo '[FAIL] alongside backend lacks minimum contiguous free-space gate' >&2; exit 1; }
grep -q 'GRUB_DISABLE_OS_PROBER' "$backend" || { echo '[FAIL] dual-boot GRUB os-prober configuration missing' >&2; exit 1; }
grep -q 'live-boot live-boot-initramfs-tools live-config live-config-systemd' "$backend" || { echo '[FAIL] installer does not purge live-only packages' >&2; exit 1; }
grep -q 'EFI/BOOT/BOOTX64.EFI' "$backend" || { echo '[FAIL] erase mode does not verify portable UEFI fallback' >&2; exit 1; }
grep -q 'EFI/Spectre/grubx64.efi' "$backend" || { echo '[FAIL] alongside mode does not verify dedicated Spectre EFI loader' >&2; exit 1; }
grep -q 'grub-install --target=i386-pc --recheck' "$backend" || { echo '[FAIL] erase mode lacks BIOS GRUB installation' >&2; exit 1; }
grep -q '/etc/spectre-installation' "$backend" || { echo '[FAIL] installer does not stamp installed-system provenance' >&2; exit 1; }
grep -q 'spectre-installed-health' "$ROOT/profiles/gnome/install-branding.sh" || { echo '[FAIL] installed-system health utility is not installed' >&2; exit 1; }
[[ -x "$ROOT/profiles/gnome/branding/build/fix-alsa-restore-rule.sh" ]] || {
    echo '[FAIL] ALSA udev compatibility repair is missing or not executable' >&2
    exit 1
}
grep -q 'fix-alsa-restore-rule.sh' "$ROOT/profiles/gnome/install-branding.sh" || {
    echo '[FAIL] install-branding does not invoke the ALSA udev compatibility repair' >&2
    exit 1
}
grep -q 'com.spectre.Installer.desktop' "$ROOT/profiles/gnome/installer/spectre-live-installer-setup" || { echo '[FAIL] live session does not promote the installer' >&2; exit 1; }
for pkg in firmware-intel-graphics firmware-iwlwifi firmware-realtek firmware-atheros firmware-brcm80211 firmware-mediatek firmware-amd-graphics firmware-nvidia-graphics firmware-sof-signed intel-microcode amd64-microcode python3-gi gir1.2-gtk-4.0 gir1.2-adw-1 locales os-prober power-profiles-daemon bluez fwupd ufw apparmor apparmor-utils systemd-zram-generator; do
    grep -q "\b$pkg\b" "$ROOT/profiles/gnome/build-live-iso.sh" || { echo "[FAIL] installer/runtime package missing from ISO build: $pkg" >&2; exit 1; }
done
printf '[OK] Installer RC4 premium guided GTK wizard, destructive-disk safety and UEFI dual-boot gates are present
'

grep -q '^Exec=/usr/local/bin/spectre-installer-launcher$' "$desktop_entry" || { echo '[FAIL] installer desktop entry bypasses launcher' >&2; exit 1; }
grep -q '^Icon=spectre-installer$' "$desktop_entry" || { echo '[FAIL] installer desktop entry does not use dedicated installer icon' >&2; exit 1; }
grep -q 'spectre-installer.png' "$ROOT/profiles/gnome/build-live-iso.sh" || { echo '[FAIL] installer icon is not installed into live image' >&2; exit 1; }
grep -q '/usr/local/sbin/spectre-installer-backend' "$ROOT/profiles/gnome/installer/49-spectre-installer.rules" || { echo '[FAIL] polkit rule does not scope authorization to backend' >&2; exit 1; }
if grep -q 'pkexec /usr/local/sbin/spectre-installer' "$launcher"; then echo '[FAIL] launcher still elevates the entire graphical installer' >&2; exit 1; fi
printf '[OK] Installer RC4 keeps the wizard unprivileged and elevates only the validated backend
'
"$ROOT/tests/test-release-boot-experience.sh"

for service_path in \
    "$ROOT/profiles/gnome/create-rootfs.sh" \
    "$ROOT/profiles/gnome/build-live-iso.sh" \
    "$ROOT/profiles/gnome/installer/spectre-installer-backend"; do
    grep -q 'systemctl mask networking.service' "$service_path" || {
        echo "[FAIL] legacy networking.service is not masked in ${service_path#$ROOT/}" >&2
        exit 1
    }
done
grep -q 'networking.service"' "$ROOT/profiles/gnome/install-branding.sh" || {
    echo '[FAIL] branded roots do not enforce the networking.service mask' >&2
    exit 1
}
printf '[OK] NetworkManager is enforced as the sole network owner in every image path\n'

grep -q 'spectre-desktop-ux@spectre.os' "$ROOT/profiles/gnome/install-branding.sh" || {
    echo '[FAIL] install-branding does not retire the legacy spectre-desktop-ux extension' >&2
    exit 1
}
grep -q 'org.gnome.shell enabled-extensions' "$ROOT/profiles/gnome/branding/spectre-gnome-style.sh" || {
    echo '[FAIL] first-login style does not define a deterministic extension allowlist' >&2
    exit 1
}
printf '[OK] legacy Spectre extensions are retired and enabled extension state is deterministic\n'
[[ -x "$ROOT/profiles/gnome/branding/bin/spectre-shell-health" ]] || {
    echo '[FAIL] Spectre Shell runtime health utility is missing' >&2
    exit 1
}
grep -q 'State:.*ACTIVE' "$ROOT/profiles/gnome/branding/bin/spectre-shell-health" || {
    echo '[FAIL] Spectre Shell runtime health utility does not qualify extension ACTIVE state' >&2
    exit 1
}
printf '[OK] runtime Shell health qualification utility is installed in source\n'

desktop_menu="$ROOT/profiles/gnome/branding/extensions/spectre-desktop-menu@spectre.os/extension.js"
grep -q "captured-event" "$desktop_menu" || {
    echo '[FAIL] Spectre desktop context menu has no stage event capture' >&2
    exit 1
}
grep -q 'global.get_window_actors' "$desktop_menu" || {
    echo '[FAIL] Spectre desktop context menu does not protect normal application windows' >&2
    exit 1
}
if grep -q 'layoutManager[.]_backgroundGroup' "$desktop_menu"; then
    echo '[FAIL] Spectre desktop context menu depends on GNOME private _backgroundGroup' >&2
    exit 1
fi
grep -q 'spectre-taskbar-settings' "$desktop_menu" || {
    echo '[FAIL] desktop context menu does not expose taskbar settings' >&2
    exit 1
}
printf '[OK] desktop context menu avoids window interception and private background actors\n'

taskbar_style="$ROOT/profiles/gnome/branding/spectre-gnome-style.sh"
grep -q "dash-to-dock intellihide true" "$taskbar_style" || {
    echo '[FAIL] Spectre taskbar smart-hide default is missing' >&2
    exit 1
}
grep -q "dash-to-dock intellihide-mode .*MAXIMIZED_WINDOWS" "$taskbar_style" || {
    echo '[FAIL] Spectre taskbar does not hide specifically for maximized windows by default' >&2
    exit 1
}
grep -q "dash-to-dock dock-fixed false" "$taskbar_style" || {
    echo '[FAIL] Spectre taskbar remains permanently fixed' >&2
    exit 1
}
grep -q 'Smart hide' "$ROOT/profiles/gnome/branding/bin/spectre-taskbar-settings" || {
    echo '[FAIL] Spectre Taskbar Settings lacks the smart-hide UI' >&2
    exit 1
}
printf '[OK] taskbar smart-hide defaults and user configuration surface are present\n'

grep -q "dash-to-dock autohide true" "$taskbar_style" || {
    echo '[FAIL] Spectre Smart Hide cannot reveal from the screen edge because Dash-to-Dock autohide is disabled' >&2
    exit 1
}
grep -q "dash-to-dock require-pressure-to-show false" "$taskbar_style" || {
    echo '[FAIL] Spectre taskbar no longer defaults to pressure-free edge reveal' >&2
    exit 1
}
grep -q "dash-to-dock pressure-threshold 35.0" "$taskbar_style" || {
    echo '[FAIL] Spectre taskbar push-to-reveal fallback threshold is missing' >&2
    exit 1
}
grep -q 'smart hide: dodge maximized windows + keep mouse-edge reveal alive' "$ROOT/profiles/gnome/branding/bin/spectre-taskbar-settings" || {
    echo '[FAIL] Spectre Taskbar Settings smart-hide path does not preserve mouse-edge reveal' >&2
    exit 1
}
grep -q 'self.set_bool("autohide", True)' "$ROOT/profiles/gnome/branding/bin/spectre-taskbar-settings" || {
    echo '[FAIL] Spectre Taskbar Settings never enables Dash-to-Dock autohide' >&2
    exit 1
}
printf '[OK] Polish8 smart-hide keeps reliable pointer edge reveal enabled\n'

grep -q "dash-to-dock animation-time 0.16" "$taskbar_style" || {
    echo '[FAIL] Spectre taskbar fast-slide duration is not the production default' >&2
    exit 1
}

grep -q "dash-to-dock show-delay 0.00" "$taskbar_style" || {
    echo '[FAIL] Spectre taskbar edge reveal is not immediate by default' >&2
    exit 1
}

grep -q "dash-to-dock hide-delay 0.12" "$taskbar_style" || {
    echo '[FAIL] Spectre taskbar hide grace is not the fast desktop default' >&2
    exit 1
}

grep -q "ding show-volumes false" "$taskbar_style" || {
    echo '[FAIL] Spectre desktop still exposes mounted-volume icons by default' >&2
    exit 1
}

grep -q "ding show-network-volumes false" "$taskbar_style" || {
    echo '[FAIL] Spectre desktop still exposes network-volume icons by default' >&2
    exit 1
}
grep -q "dash-to-dock customize-alphas true" "$taskbar_style" || {
    echo '[FAIL] Spectre taskbar does not enable explicit glass alpha controls' >&2
    exit 1
}
grep -q "dash-to-dock min-alpha 0.16" "$taskbar_style" || {
    echo '[FAIL] Spectre taskbar floating alpha is not configured' >&2
    exit 1
}
grep -q 'Slide duration' "$ROOT/profiles/gnome/branding/bin/spectre-taskbar-settings" || {
    echo '[FAIL] Spectre Taskbar Settings lacks motion control' >&2
    exit 1
}
grep -q 'Floating opacity' "$ROOT/profiles/gnome/branding/bin/spectre-taskbar-settings" || {
    echo '[FAIL] Spectre Taskbar Settings lacks opacity control' >&2
    exit 1
}

grep -q 'self.set_double("show-delay", 0.00)' "$ROOT/profiles/gnome/branding/bin/spectre-taskbar-settings" || {
    echo '[FAIL] Spectre Taskbar Settings can reintroduce reveal latency' >&2
    exit 1
}

grep -q 'value \* 0.75' "$ROOT/profiles/gnome/branding/bin/spectre-taskbar-settings" || {
    echo '[FAIL] Spectre Taskbar Settings fast hide timing is missing' >&2
    exit 1
}

grep -q 'desktop-unified-rc56-fastdesktop-v1' "$ROOT/profiles/gnome/branding/bin/spectre-desktop-state" || {
    echo '[FAIL] Fast Desktop DING migration marker missing' >&2
    exit 1
}
grep -q "Main.overview.connect('showing'" "$desktop_menu" || {
    echo '[FAIL] desktop menu does not close when GNOME Overview/app-grid opens' >&2
    exit 1
}
[[ -f "$ROOT/profiles/gnome/branding/etc-skel/.config/gtk-4.0/gtk.css" ]] || {
    echo '[FAIL] GTK 4 glass popover compatibility CSS is missing' >&2
    exit 1
}
printf '[OK] Polish7/Polish8 taskbar motion, transparency, edge reveal and menu lifecycle safeguards are present\n'

grep -q "^[[:space:]]*State:" "$ROOT/profiles/gnome/branding/bin/spectre-shell-health" || true
if grep -q "grep -Eq '\^State:" "$ROOT/profiles/gnome/branding/bin/spectre-shell-health"; then
    echo '[FAIL] shell health checker still rejects indented gnome-extensions state output' >&2
    exit 1
fi
printf '[OK] shell health checker accepts indented GNOME extension ACTIVE state\n'

grep -q 'sync-runtime-root.sh" "$STAGE" live' "$ROOT/profiles/gnome/build-live-iso.sh" || {
    echo '[FAIL] live ISO builder does not synchronize current Spectre source into the staged runtime' >&2
    exit 1
}
grep -q 'sync-runtime-root.sh" "$TARGET" uefi-template' "$ROOT/profiles/gnome/build-uefi.sh" || {
    echo '[FAIL] UEFI builder does not synchronize current Spectre source into the template rootfs' >&2
    exit 1
}
grep -q 'source-sha256' "$ROOT/profiles/gnome/run-qemu-iso.sh" || {
    echo '[FAIL] ISO runner has no stale-artifact source-hash guard' >&2
    exit 1
}
grep -q 'source-sha256' "$ROOT/profiles/gnome/run-qemu-uefi.sh" || {
    echo '[FAIL] UEFI runner has no stale-artifact source-hash guard' >&2
    exit 1
}
grep -q 'etc/spectre-build' "$ROOT/profiles/gnome/verify-live-iso.sh" || {
    echo '[FAIL] live ISO verifier does not prove runtime source provenance' >&2
    exit 1
}
printf '[OK] source-to-runtime synchronization and stale-artifact guards are wired into build/test paths\n'

"$ROOT/profiles/gnome/personal-apps/validate-managed-apps.sh"
"$ROOT/profiles/gnome/verify-product-boundaries.sh" "$ROOT/.no-rootfs"
"$ROOT/tests/test-v1-app-framework.sh"
"$ROOT/tests/test-v1-windows-shortcuts.sh"
"$ROOT/tests/test-v1-files-launcher.sh"
"$ROOT/tests/test-v1-core-only-release.sh"
"$ROOT/tests/test-v1-libreoffice-stable-profile.sh"
"$ROOT/tests/test-v1-production-build-session.sh"
"$ROOT/tests/test-v1-build-workdir-permissions.sh"
"$ROOT/tests/test-runtime-source-sync.sh"
"$ROOT/tests/test-installer-rc2.sh"
"$ROOT/tests/test-installer-rc4.sh"
"$ROOT/tests/test-rc42-ux.sh"
"$ROOT/tests/test-rc43-installer-safety-ux.sh"
"$ROOT/tests/test-rc44-build-resource-safety.sh"
"$ROOT/tests/test-rc45-installer-runtime-ux.sh"
"$ROOT/tests/test-rc46-account-postprocess.sh"
"$ROOT/tests/test-rc50-installed-qualification.sh"
"$ROOT/tests/test-rc5-daily-foundation.sh"
"$ROOT/tests/test-rc51-identity-desktop-ux.sh"
"$ROOT/tests/test-rc52-app-actions.sh"
"$ROOT/tests/test-rc53-app-actions-runtime-contract.sh"
"$ROOT/tests/test-rc54-desktop-hardware.sh"
"$ROOT/tests/test-rc55-desktop-unification.sh"
"$ROOT/tests/test-rc56-runtime-ui-installer.sh"
"$ROOT/tests/test-rc561-desktop-menu-insight.sh"
"$ROOT/tests/test-rc562-desktop-provider.sh"
"$ROOT/tests/test-rc6-physical-boot-health-apps.sh"
"$ROOT/tests/test-v1-production-release.sh"

# SPECTRE_FIRSTBOOT_UI_V1 regression gate
"$ROOT/tests/test-v1-desktop-menu-firstboot.sh"
# SPECTRE_GDM_LOCKSCREEN_SOURCE_V1 regression gate
"$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)/tests/test-v1-gdm-lockscreen-source.sh"
"$ROOT/tests/test-v1-gdm-compact-logo.sh"
"$ROOT/tests/test-v1-installer-responsive-layout.sh"
"$ROOT/tests/test-v1-installing-page-polish.sh"
"$ROOT/tests/test-v1-vbox-early-kms.sh"
"$ROOT/tests/test-v1-ding-provider-migration.sh"
"$ROOT/tests/test-v1-realos-production-hardening.sh"
# SPECTRE_RC1_RECOVERY_BUILD_PATH_V1
RECOVERY_AUDITOR="$ROOT/profiles/gnome/audit-rc1-recovery.py"

[[ -x "$RECOVERY_AUDITOR" ]] || {
    echo '[FAIL] RC1 recovery auditor is missing or not executable' >&2
    exit 1
}

python3 - "$RECOVERY_AUDITOR" <<'PYREC'
from pathlib import Path
import sys

p = Path(sys.argv[1])
compile(p.read_text(), str(p), "exec")
PYREC

grep -q 'SPECTRE_RECOVERY_ISO' \
    "$ROOT/profiles/gnome/build-live-iso.sh" || {
    echo '[FAIL] live ISO builder lacks RC1 recovery mode' >&2
    exit 1
}

grep -q 'Recovering qualified RC1 live root' \
    "$ROOT/profiles/gnome/build-live-iso.sh" || {
    echo '[FAIL] live ISO builder lacks RC1 SquashFS recovery path' >&2
    exit 1
}

grep -q 'audit-rc1-recovery.py' \
    "$ROOT/profiles/gnome/verified-module-stage.sh" || {
    echo '[FAIL] module bridge lacks RC1 recovery auditor' >&2
    exit 1
}

for input in \
    verified-module-stage.sh \
    audit-module-bridge.py \
    audit-rc1-recovery.py \
    verify-packaged-modules.sh
do
    grep -q "$input" \
        "$ROOT/profiles/gnome/runtime-source-hash.sh" || {
        echo "[FAIL] $input is outside runtime provenance" >&2
        exit 1
    }
done

# Validate recovery trust anchors semantically.  The auditor intentionally
# permits adjacent Python string literals, so textual grep of a 64-character
# digest is not a valid integrity check.
python3 - "$RECOVERY_AUDITOR" <<'PYRECID'
import ast
from pathlib import Path
import sys

path = Path(sys.argv[1])

expected = {
    "RC1_ISO_SHA256":
        "473fad1fc51baf9968081650599ecbd11"
        "f424834c8a4a63174f901c973fdde8b",

    "RC1_MODULE_TREE_SHA256":
        "1b5338902cd9ee96e12105176a6005e9"
        "be82c5a83294380c5ed28852980b3e18",

    "RC1_KERNEL_SHA256":
        "3055172a10be060591ae473ce14dceb21"
        "ce37c5caa6bd444b8a6d0c51a6299eb",

    "RC1_CONFIG_SHA256":
        "edc51391c20945c651584f1f661a7c06"
        "23bf5e2f87b0de3ce8ed7deb29b7e7e8",
}

tree = ast.parse(
    path.read_text(),
    filename=str(path),
)

found = {}

for node in tree.body:
    if not isinstance(node, ast.Assign):
        continue

    if len(node.targets) != 1:
        continue

    target = node.targets[0]

    if not isinstance(target, ast.Name):
        continue

    name = target.id

    if name not in expected:
        continue

    try:
        value = ast.literal_eval(node.value)
    except Exception as exc:
        raise SystemExit(
            f"[FAIL] Could not evaluate trust anchor {name}: {exc}"
        )

    found[name] = value

missing = sorted(set(expected) - set(found))

if missing:
    raise SystemExit(
        "[FAIL] Recovery auditor trust anchors missing: "
        + ", ".join(missing)
    )

for name, required in expected.items():
    actual = found[name]

    if actual != required:
        raise SystemExit(
            f"[FAIL] Recovery trust anchor mismatch: {name}\n"
            f"       expected={required}\n"
            f"       actual={actual}"
        )

print(
    "[PASS] RC1 recovery ISO/module/kernel/config "
    "trust anchors are exactly pinned."
)
PYRECID

printf '[OK] RC1 ISO recovery path is fail-closed and provenance-covered\n'

# SPECTRE_STATIC_MARKUP_AMPERSAND_V1
python3 - "$ROOT" <<'PYAMP'
from pathlib import Path
import sys

root = Path(sys.argv[1])

checks = {
    "profiles/gnome/branding/bin/spectre-taskbar-settings": [
        (
            'title="Appearance &amp; motion"',
            'title="Appearance & motion"',
        ),
    ],

    "profiles/gnome/branding/bin/spectre-welcome": [
        (
            'title="Appearance &amp; desktop"',
            'title="Appearance & desktop"',
        ),
        (
            'title="Desktop apps &amp; icons"',
            'title="Desktop apps & icons"',
        ),
        (
            'title="Wallpaper &amp; display"',
            'title="Wallpaper & display"',
        ),
    ],

    "profiles/gnome/branding/bin/spectre-shortcuts": [
        (
            "'Windows &amp; workspaces'",
            "'Windows & workspaces'",
        ),
        (
            "'Devices &amp; capture'",
            "'Devices & capture'",
        ),
    ],
}

for rel, pairs in checks.items():
    path = root / rel
    text = path.read_text()

    for escaped, unsafe in pairs:
        if text.count(escaped) != 1:
            raise SystemExit(
                f"[FAIL] expected markup-safe title missing: "
                f"{rel}: {escaped}"
            )

        if unsafe in text:
            raise SystemExit(
                f"[FAIL] unescaped markup ampersand returned: "
                f"{rel}: {unsafe}"
            )

print(
    "[PASS] Spectre static libadwaita titles have "
    "markup-safe ampersands."
)
PYAMP

# SPECTRE_RECOVERY_RELEASE_CHECK_V1
RELEASE_CHECK="$ROOT/profiles/gnome/release-check.sh"

grep -Fq 'SPECTRE_RECOVERY_RELEASE_PREFLIGHT_V1' \
    "$RELEASE_CHECK" || {
        echo '[FAIL] release-check lacks recovery-aware source selection' >&2
        exit 1
    }

grep -Fq 'Missing recovery ISO:' \
    "$RELEASE_CHECK" || {
        echo '[FAIL] release-check does not fail closed on missing recovery ISO' >&2
        exit 1
    }

grep -Fq 'Missing UEFI image:' \
    "$RELEASE_CHECK" || {
        echo '[FAIL] legacy UEFI-image release guard was removed' >&2
        exit 1
    }

grep -Fq '"$ROOT/profiles/gnome/release-check.sh"' \
    "$ROOT/profiles/gnome/runtime-source-hash.sh" || {
        echo '[FAIL] release-check is not runtime-provenance covered' >&2
        exit 1
    }

printf '[PASS] recovery-aware release-check is fail-closed and provenance-covered.\n'

# SPECTRE_RECOVERY_RELEASE_ROOTFS_GATE_V2
RELEASE_CHECK="$ROOT/profiles/gnome/release-check.sh"

grep -Fq 'SPECTRE_RECOVERY_RELEASE_ROOTFS_V2' \
    "$RELEASE_CHECK" || {
        echo '[FAIL] release-check lacks recovery ISO rootfs acquisition' >&2
        exit 1
    }

grep -Fq '/live/filesystem.squashfs' \
    "$RELEASE_CHECK" || {
        echo '[FAIL] release-check does not inspect recovery SquashFS' >&2
        exit 1
    }

grep -Fq 'xorriso' \
    "$RELEASE_CHECK" || {
        echo '[FAIL] recovery ISO extraction tool contract missing' >&2
        exit 1
    }

grep -Fq 'losetup --find --show --read-only --partscan "$IMAGE"' \
    "$RELEASE_CHECK" || {
        echo '[FAIL] legacy UEFI-image inspection path was removed' >&2
        exit 1
    }

grep -Fq 'sudo mount -o ro -t squashfs "$loop" "$mnt"' \
    "$RELEASE_CHECK" || {
        echo '[FAIL] recovery SquashFS is not mounted read-only' >&2
        exit 1
    }

printf '[PASS] release-check validates both recovery SquashFS and legacy UEFI roots.\n'

echo '[ok] Spectre GNOME project validation passed.'


# SPECTRE_TOOLHUB_VALIDATE_V1 BEGIN
"$ROOT/profiles/gnome/toolhub/validate-toolhub.sh"
# SPECTRE_TOOLHUB_VALIDATE_V1 END
