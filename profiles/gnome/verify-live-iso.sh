#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/config/release.conf"
ISO="${SPECTRE_ISO:-$ROOT/iso/$SPECTRE_ISO_FILENAME}"
ok(){ printf '[OK]   %s\n' "$*"; }
bad(){ printf '[FAIL] %s\n' "$*" >&2; exit 1; }
[[ -f "$ISO" ]] || { echo "[FAIL] ISO missing: $ISO" >&2; exit 1; }
CURRENT_SOURCE_HASH="$("$ROOT/profiles/gnome/runtime-source-hash.sh")"
ISO_SOURCE_HASH="$(awk 'NR==1{print $1}' "$ISO.source-sha256" 2>/dev/null || true)"
[[ "$ISO_SOURCE_HASH" == "$CURRENT_SOURCE_HASH" ]] && ok 'ISO runtime-source sidecar matches current source' || bad "ISO runtime-source sidecar is stale/missing (iso=${ISO_SOURCE_HASH:-missing}, current=$CURRENT_SOURCE_HASH)"
for c in xorriso unsquashfs lsinitramfs unmkinitramfs chroot python3 cmp; do command -v "$c" >/dev/null || { echo "[FAIL] Missing $c" >&2; exit 1; }; done
W="$(mktemp -d)"; trap 'sudo rm -rf "$W" >/dev/null 2>&1 || true' EXIT
xorriso -osirrox on -indev "$ISO" -extract /live/initrd.img "$W/initrd.img" >/dev/null 2>&1
xorriso -osirrox on -indev "$ISO" -extract /live/filesystem.squashfs "$W/filesystem.squashfs" >/dev/null 2>&1
xorriso -osirrox on -indev "$ISO" -extract /boot/grub/grub.cfg "$W/grub.cfg" >/dev/null 2>&1
xorriso -osirrox on -indev "$ISO" -extract /live/kernel.config "$W/kernel.config" >/dev/null 2>&1 || bad 'kernel.config missing from ISO'

python3 - "$W/grub.cfg" "$SPECTRE_PRETTY_NAME" <<'PYGRUB'
from pathlib import Path
import re, sys
text=Path(sys.argv[1]).read_text()
pretty=sys.argv[2]
entries={m.group(1):m.group(2) for m in re.finditer(r"menuentry '([^']+)'[^\{]*\{(.*?)\n\}", text, re.S)}

def line(name):
    block=entries.get(name, '')
    for raw in block.splitlines():
        if raw.strip().startswith('linux /live/vmlinuz'):
            return raw.strip()
    return ''

def need(cond, good, bad):
    if not cond:
        print('[FAIL] '+bad, file=sys.stderr); raise SystemExit(1)
    print('[OK]   '+good)

general=[
    f'Try or Install {pretty}',
    f'{pretty} - Safe graphics',
    f'{pretty} - Text diagnostics',
    f'{pretty} - Initramfs diagnostics',
]
for name in general:
    ln=line(name)
    need(bool(ln), f'GRUB entry present: {name}', f'GRUB entry missing: {name}')
    need('boot=live' in ln, f'live-boot enabled: {name}', f'boot=live missing: {name}')
    need('rootfstype=ramfs' in ln and 'rdinit=/init' in ln, f'early root contract retained: {name}', f'ramfs/init contract missing: {name}')
    need('live-media-path=/live' in ln and 'live-media-timeout=30' in ln, f'30s automatic media discovery: {name}', f'physical-media discovery contract missing: {name}')
    need('live-media=' not in ln, f'no hardcoded media device: {name}', f'general entry hardcodes media device: {name}')
q=line(f'{pretty} - QEMU optical compatibility')
need(bool(q), 'QEMU optical compatibility entry present', 'QEMU optical compatibility entry missing')
need('live-media=/dev/sr0' in q, 'QEMU optical entry pins /dev/sr0 only', 'QEMU optical entry lost /dev/sr0')
need('live-media-timeout=30' in q, 'QEMU optical entry uses sane timeout', 'QEMU optical timeout is not 30s')
need('live-media-timeout=1' not in text, 'obsolete one-second media timeout removed', 'obsolete one-second media timeout remains')
need('systemd.unit=graphical.target' in line(general[0]), 'normal GRUB path forces graphical.target', 'graphical.target missing from normal boot')
need('console=ttyS0,115200 console=tty0' in text, 'serial diagnostics remain in recovery/compatibility entries', 'diagnostic serial console path missing')
PYGRUB

NORMAL_LINUX="$(awk '/menuentry .Try or Install/{in_default=1; next} in_default && /^[[:space:]]*linux \/live\/vmlinuz/{sub(/^[[:space:]]*/,""); print; exit}' "$W/grub.cfg")"
[[ "$NORMAL_LINUX" == *' quiet splash '* ]] && ok 'normal live boot enables Plymouth quiet splash' || bad 'normal live boot lost quiet splash'
[[ "$NORMAL_LINUX" == *'systemd.show_status=false'* && "$NORMAL_LINUX" == *'rd.systemd.show_status=false'* ]] && ok 'normal live boot hides systemd debug/status output' || bad 'normal live boot still exposes systemd status output'
[[ "$NORMAL_LINUX" != *'console=ttyS0'* ]] && ok 'normal live boot no longer uses the serial debug console' || bad 'normal live boot still forces serial diagnostics'
python3 - "$W/initrd.img" <<'PYC'
import sys
data=open(sys.argv[1],'rb').read()
magics={'gzip':b'\x1f\x8b\x08','zstd':b'\x28\xb5\x2f\xfd','xz':b'\xfd7zXZ\x00','bzip2':b'BZh','lz4':b'\x04\x22\x4d\x18'}
hits=[(data.find(m),n) for n,m in magics.items() if data.find(m)>=0]
if not hits:
    print('[FAIL] no recognized initramfs compression payload', file=sys.stderr); sys.exit(1)
pos,name=min(hits)
print(f'[OK]   initramfs compressed payload: {name} (offset {pos})')
if name!='gzip':
    print('[FAIL] initramfs main payload is not gzip', file=sys.stderr); sys.exit(1)
PYC
LIST="$W/initramfs.list"; lsinitramfs "$W/initrd.img" > "$LIST"
grep -Eq '(^|/)usr/share/plymouth/themes/spectre/spectre[.]plymouth$' "$LIST" && ok 'Spectre Plymouth theme embedded in live initramfs' || bad 'Spectre Plymouth theme missing from live initramfs'
grep -Eq '(^|/)scripts/live$' "$LIST" && ok '/scripts/live embedded' || bad '/scripts/live missing from live initramfs'
grep -Eq '(^|/)(usr/)?bin/live-boot$' "$LIST" && ok 'live-boot executable embedded' || bad 'live-boot executable missing'
grep -Eq '(^|/)usr/lib/live/boot/9990-main\.sh$' "$LIST" && ok 'live-boot components embedded' || bad 'live-boot components missing'
grep -Eq '(^|/)init$' "$LIST" && ok 'primary /init embedded' || bad 'primary /init missing from live initramfs'
grep -Eq '(^|/)bin/sh$' "$LIST" && ok '/bin/sh interpreter embedded' || bad '/bin/sh missing from live initramfs'
grep -Eq '(^|/)(usr/)?bin/busybox$' "$LIST" && ok 'busybox embedded' || bad 'busybox missing from live initramfs'
verify_capability() {
  local sym="$1" regex="$2" label="$3"
  if grep -q "^${sym}=y$" "$W/kernel.config"; then
    ok "$label built into kernel; no .ko required"
  elif grep -q "^${sym}=m$" "$W/kernel.config"; then
    grep -Eq "$regex" "$LIST" && ok "$label module embedded in live initramfs" || bad "$label is =m but module missing from live initramfs"
  else
    bad "$label disabled in kernel config ($sym)"
  fi
}
verify_capability CONFIG_ISO9660_FS  '(^|/)lib/modules/.*/kernel/fs/isofs/isofs\.ko(\..*)?$' 'ISO9660/isofs'
verify_capability CONFIG_OVERLAY_FS  '(^|/)lib/modules/.*/kernel/fs/overlayfs/overlay\.ko(\..*)?$' 'overlayfs'
verify_capability CONFIG_SCSI_VIRTIO '(^|/)lib/modules/.*/kernel/drivers/scsi/virtio_scsi\.ko(\..*)?$' 'VirtIO-SCSI'

# SPECTRE_VBOX_EARLY_KMS_VERIFY_V1
verify_initramfs_module() {
  local regex="$1" label="$2"
  grep -Eq "$regex" "$LIST"     && ok "$label embedded in live initramfs"     || bad "$label missing from live initramfs"
}
verify_initramfs_module '(^|/)lib/modules/.*/kernel/drivers/gpu/drm/ttm/ttm\.ko(\..*)?$' 'TTM'
verify_initramfs_module '(^|/)lib/modules/.*/kernel/drivers/gpu/drm/drm_ttm_helper\.ko(\..*)?$' 'DRM TTM helper'
verify_initramfs_module '(^|/)lib/modules/.*/kernel/drivers/gpu/drm/drm_vram_helper\.ko(\..*)?$' 'DRM VRAM helper'
verify_initramfs_module '(^|/)lib/modules/.*/kernel/drivers/gpu/drm/vmwgfx/vmwgfx\.ko(\..*)?$' 'VirtualBox VMSVGA/vmwgfx'
verify_initramfs_module '(^|/)lib/modules/.*/kernel/drivers/gpu/drm/vboxvideo/vboxvideo\.ko(\..*)?$' 'VirtualBox VBoxSVGA/vboxvideo'

# Runtime smoke-test of the exact /init -> /bin/sh execution chain.
mkdir -p "$W/initrd-extract"
sudo unmkinitramfs "$W/initrd.img" "$W/initrd-extract" >/dev/null
if [[ -f "$W/initrd-extract/main/init" ]]; then IR="$W/initrd-extract/main"; else IR="$W/initrd-extract"; fi
[[ -f "$IR/init" && -x "$IR/init" ]] && ok '/init is regular + executable' || bad '/init is not a regular executable file'
[[ "$(head -n1 "$IR/init")" == '#!/bin/sh' ]] && ok '/init shebang is /bin/sh' || bad '/init shebang is invalid'
TARGET="$(readlink -f "$IR/bin/sh" 2>/dev/null || true)"
[[ -n "$TARGET" && "$TARGET" == "$IR"/* && -x "$TARGET" ]] && ok '/bin/sh resolves to executable inside initramfs' || bad '/bin/sh target is broken'
sudo chroot "$IR" /bin/sh -c 'printf SPECTRE_INITRAMFS_SHELL_OK' | grep -qx 'SPECTRE_INITRAMFS_SHELL_OK' && ok '/bin/sh execution smoke test' || bad '/bin/sh cannot execute inside initramfs'
COMPRESSED_BYTES="$(stat -c %s "$W/initrd.img")"
UNPACKED_BYTES="$(sudo du -sb "$W/initrd-extract" | awk '{print $1}')"
MODULE_COUNT="$(grep -Ec '(^|/)lib/modules/.*/.*\.ko(\..*)?$' "$LIST" || true)"
NET_MODULE_COUNT="$(grep -Ec '(^|/)lib/modules/.*/kernel/drivers/net/.*\.ko(\..*)?$' "$LIST" || true)"
printf '[OK]   initramfs footprint: compressed=%s MiB extracted=%s MiB modules=%s net-modules=%s\n' \
  "$(( (COMPRESSED_BYTES + 1048575) / 1048576 ))" \
  "$(( (UNPACKED_BYTES + 1048575) / 1048576 ))" "$MODULE_COUNT" "$NET_MODULE_COUNT"
(( MODULE_COUNT <= 180 )) || bad "initramfs contains $MODULE_COUNT modules; live-hook bloat remains"
ok 'initramfs module count is below 180-module safety ceiling'
(( UNPACKED_BYTES <= 1024 * 1024 * 1024 )) || bad 'initramfs expands beyond 1 GiB safety ceiling'
ok 'initramfs extracted footprint is below 1 GiB safety ceiling'
# RC5.6 security boundary: verify immutable SquashFS metadata for / itself.
SQUASH_ROOT_META="$(unsquashfs -ll "$W/filesystem.squashfs" 2>/dev/null | grep -m1 -E 'squashfs-root$' || true)"
[[ "$SQUASH_ROOT_META" =~ ^d[rwx-]{9}[[:space:]]+root/root[[:space:]] ]] \
  && ok 'live SquashFS root is root:root' \
  || bad "live SquashFS root ownership is unsafe: ${SQUASH_ROOT_META:-metadata unavailable}"

unsquashfs -cat "$W/filesystem.squashfs" etc/os-release > "$W/os-release"
grep -q '^ID=spectre$' "$W/os-release" && ok 'Spectre OS identity in live root' || bad 'Spectre identity missing'
grep -Fqx "PRETTY_NAME=\"$SPECTRE_PRETTY_NAME\"" "$W/os-release" && ok 'release identity matches config/release.conf' || bad 'release identity drift detected'

# Prove the SquashFS contains the current source rather than whatever happened
# to be present in an older UEFI engineering image.
unsquashfs -cat "$W/filesystem.squashfs" etc/spectre-build > "$W/spectre-build" || bad '/etc/spectre-build missing from live root'
LIVE_SOURCE_HASH="$(sed -n 's/^RUNTIME_SOURCE_SHA256=//p' "$W/spectre-build" | head -1)"
[[ "$LIVE_SOURCE_HASH" == "$CURRENT_SOURCE_HASH" ]] && ok 'live root runtime-source stamp matches current source' || bad "live root source hash mismatch (live=${LIVE_SOURCE_HASH:-missing}, current=$CURRENT_SOURCE_HASH)"
grep -Fqx "BUILD_ID=$SPECTRE_BUILD_ID" "$W/spectre-build" && ok 'live root build ID matches release config' || bad 'live root build ID drift detected'

unsquashfs -cat "$W/filesystem.squashfs" etc/shadow > "$W/live-shadow" || bad 'live /etc/shadow missing'
LIVE_HASH="$(awk -F: '$1=="spectre"{print $2; exit}' "$W/live-shadow")"
[[ -z "$LIVE_HASH" ]] && ok 'live spectre account has no password' || bad 'live spectre account still carries a password hash'
unsquashfs -cat "$W/filesystem.squashfs" etc/sudoers.d/90-spectre-live > "$W/live-sudoers" 2>/dev/null || bad 'live passwordless sudo policy missing'
grep -Fq 'spectre ALL=(ALL:ALL) NOPASSWD: ALL' "$W/live-sudoers" && ok 'live session passwordless administration policy present' || bad 'live NOPASSWD policy invalid'

for spec in \
  'spectre-panel@spectre.os' \
  'spectre-hud@spectre.os' \
  'spectre-desktop-menu@spectre.os'; do
  src="$ROOT/profiles/gnome/branding/extensions/$spec/extension.js"
  dst="$W/$spec.extension.js"
  unsquashfs -cat "$W/filesystem.squashfs" "usr/share/gnome-shell/extensions/$spec/extension.js" > "$dst" || bad "$spec extension missing from live root"
  cmp -s "$src" "$dst" && ok "$spec source exactly matches live SquashFS" || bad "$spec in ISO does not match current source"
done

for runtime_path in \
  usr/local/bin/spectre-shell-health \
  usr/local/bin/spectre-taskbar-settings \
  usr/local/bin/spectre-desktop-refresh \
  usr/local/bin/spectre-ding-reload \
  usr/local/bin/spectre-appearance-sync \
  usr/local/bin/spectre-desktop-apps \
  usr/local/bin/spectre-desktop-state \
  usr/local/bin/spectre-run \
  usr/local/bin/spectre-power-menu \
  usr/local/bin/spectre-files \
  usr/local/bin/spectre-shortcut-defaults \
  usr/local/bin/spectre-shortcuts \
  usr/local/bin/spectre-lock \
  usr/local/bin/spectre-clipboard \
  usr/local/bin/spectre-update-manager \
  usr/local/bin/spectre-hardware \
  usr/local/bin/spectre-hardware-qualification \
  usr/local/bin/spectre-suspend-qualification \
  usr/local/bin/spectre-recovery \
  usr/local/sbin/spectre-patch-ding \
  etc/grub.d/42_spectre_recovery \
  usr/local/bin/spectre-installed-health \
  usr/local/bin/spectre-installed-qualification \
  usr/local/bin/spectre-status \
  usr/local/bin/spectre-support-report \
  usr/local/bin/spectre-qualification \
  usr/local/sbin/spectre-maintenance \
  usr/local/sbin/spectre-installed-sanitize \
  usr/local/sbin/spectre-boot-record \
  etc/systemd/system/spectre-boot-record.service \
  etc/systemd/system/spectre-maintenance.service \
  etc/systemd/system/spectre-maintenance.timer \
  etc/systemd/system/spectre-installed-sanitize.service \
  etc/systemd/journald.conf.d/90-spectre.conf \
  etc/systemd/zram-generator.conf \
  usr/local/bin/spectre-live-installer-setup \
  usr/local/bin/spectre-installer-launcher \
  usr/local/sbin/spectre-installer \
  usr/local/sbin/spectre-installer-backend \
  usr/share/applications/com.spectre.TaskbarSettings.desktop \
  usr/share/applications/com.spectre.DesktopApps.desktop \
  usr/share/applications/com.spectre.Shortcuts.desktop \
  usr/share/applications/com.spectre.UpdateManager.desktop \
  usr/share/applications/com.spectre.Installer.desktop \
  usr/share/pixmaps/spectre-installer.png \
  usr/share/icons/hicolor/256x256/apps/spectre-installer.png \
  etc/xdg/autostart/spectre-live-installer.desktop \
  etc/xdg/autostart/spectre-appearance-sync.desktop \
  etc/xdg/autostart/spectre-clipboard.desktop \
  etc/xdg/autostart/spectre-desktop-state.desktop \
  usr/share/backgrounds/spectre/collection/spectre-default-dark.png \
  usr/share/backgrounds/spectre/collection/spectre-default-light.png \
  usr/share/themes/Spectre-Day/gnome-shell/gnome-shell.css \
  etc/polkit-1/rules.d/49-spectre-installer.rules; do
  unsquashfs -ll "$W/filesystem.squashfs" "$runtime_path" 2>/dev/null | grep -Fq "/$runtime_path" \
    && ok "$runtime_path present in live root" \
    || bad "$runtime_path missing from live root"
done

# RC5.1 identity and appearance gates.
unsquashfs -cat "$W/filesystem.squashfs" usr/share/gnome-background-properties/spectre.xml > "$W/spectre-wallpapers.xml" || bad 'Spectre wallpaper catalog missing'
grep -Fq '<name>Spectre Default</name>' "$W/spectre-wallpapers.xml" && ok 'Spectre paired default wallpaper is registered' || bad 'Spectre Default wallpaper catalog entry missing'
grep -Fq 'spectre-default-light.png' "$W/spectre-wallpapers.xml" && grep -Fq 'spectre-default-dark.png' "$W/spectre-wallpapers.xml" && ok 'Spectre light/dark wallpaper pair is registered' || bad 'Spectre light/dark wallpaper pair missing'
[[ $(grep -c '<wallpaper deleted="false">' "$W/spectre-wallpapers.xml") -ge 15 ]] && ok 'Spectre curated wallpaper collection is present' || bad 'Spectre wallpaper collection is incomplete'

# RC5.4 full-desktop integration: DING owns the file-backed desktop, so
# Spectre patches that single menu rather than enabling a competing Shell menu.
DING_DM='usr/share/gnome-shell/extensions/ding@rastersoft.com/app/desktopManager.js'
unsquashfs -cat "$W/filesystem.squashfs" "$DING_DM" > "$W/ding-desktopManager.js" 2>/dev/null || bad 'qualified DING desktopManager.js missing'
grep -Fq 'SPECTRE_RC54_DING_REFRESH' "$W/ding-desktopManager.js" && ok 'DING full-desktop menu contains Spectre Refresh' || bad 'Spectre Refresh integration missing from DING'
grep -Fq 'SPECTRE_RC55_DING_MENU' "$W/ding-desktopManager.js" && ok 'DING full-desktop menu contains Spectre system actions' || bad 'Spectre RC5.5 system actions missing from DING'

# RC5.6 deterministic right-click/theme fallback.  DING still owns files, but
# the Shell fallback must be enabled so uncovered background areas never expose
# GNOME's unrelated 3-item menu during display geometry changes.
unsquashfs -cat "$W/filesystem.squashfs" usr/local/bin/spectre-gnome-style > "$W/spectre-gnome-style" 2>/dev/null || bad 'Spectre GNOME style helper missing'
grep -F "enabled-extensions" "$W/spectre-gnome-style" | grep -Fq "'spectre-desktop-menu@spectre.os'" \
  && ok 'Spectre Shell desktop fallback enabled with DING' \
  || bad 'Spectre Shell desktop fallback is not enabled in default session state'
unsquashfs -cat "$W/filesystem.squashfs" etc/dconf/db/local.d/00-spectre > "$W/spectre-dconf" 2>/dev/null || bad 'Spectre system dconf defaults missing'
grep -Fq "gtk-theme='Adwaita-dark'" "$W/spectre-dconf" \
  && ok 'GTK3 dark default is set before DING startup' \
  || bad 'GTK3 dark default is missing; DING may launch with inconsistent light menu styling'
grep -Fq "'spectre-desktop-menu@spectre.os', 'ding@rastersoft.com'" "$W/spectre-dconf" \
  && ok 'first-frame DING + Spectre background fallback defaults are registered' \
  || bad 'system dconf does not enable DING + Spectre background fallback before user autostart'

# Physical-machine RC1 needs common CPU/GPU/Wi-Fi/audio firmware in the
# SquashFS so the installed system does not depend on network access for first boot.
unsquashfs -cat "$W/filesystem.squashfs" var/lib/dpkg/status > "$W/dpkg-status" || bad 'dpkg status database missing from live root'
for pkg in   python3-venv python3-tk python3-gi gir1.2-gtk-4.0 gir1.2-adw-1 locales os-prober ntfs-3g gnome-shell-extension-desktop-icons-ng   libreoffice-writer libreoffice-calc libreoffice-impress libreoffice-draw libreoffice-math libreoffice-gnome libreoffice-gtk3 libreoffice-style-colibre   power-profiles-daemon bluez fwupd ufw apparmor apparmor-utils systemd-zram-generator pciutils usbutils mesa-utils smartmontools nvme-cli acpi switcheroo-control   firmware-intel-graphics firmware-intel-misc firmware-iwlwifi firmware-realtek   firmware-atheros firmware-brcm80211 firmware-mediatek firmware-libertas   firmware-amd-graphics firmware-nvidia-graphics firmware-misc-nonfree   firmware-sof-signed intel-microcode amd64-microcode; do
  awk -v p="$pkg" 'BEGIN{RS=""; FS="\n"} $0 ~ "(^|\n)Package: " p "(\n|$)" && $0 ~ "\nStatus: install ok installed(\n|$)" {found=1} END{exit !found}' "$W/dpkg-status"     && ok "$pkg installed for physical-hardware coverage"     || bad "$pkg missing from live root"
done

# RC5 daily-use policy files are intentionally part of the live image so the
# installed copy has the same bounded-journal, zram and first-boot maintenance baseline.
unsquashfs -cat "$W/filesystem.squashfs" etc/systemd/zram-generator.conf > "$W/zram.conf" || bad 'zram policy missing from live root'
grep -Fq 'compression-algorithm = zstd' "$W/zram.conf" && ok 'zram uses zstd compressed-memory policy' || bad 'zram compression policy drifted'
unsquashfs -cat "$W/filesystem.squashfs" etc/systemd/journald.conf.d/90-spectre.conf > "$W/journald.conf" || bad 'journald resource policy missing'
grep -Fq 'SystemMaxUse=256M' "$W/journald.conf" && ok 'journald persistent storage is bounded' || bad 'journald storage bound missing'
unsquashfs -cat "$W/filesystem.squashfs" etc/ufw/ufw.conf > "$W/ufw.conf" 2>/dev/null || bad 'UFW configuration missing'
grep -Fq 'ENABLED=yes' "$W/ufw.conf" && ok 'desktop firewall is enabled by default' || bad 'UFW default enablement missing'

SQUASH_LIST="$W/squashfs.list"
unsquashfs -ll "$W/filesystem.squashfs" > "$SQUASH_LIST"
grep -E '/etc/systemd/system/networking.service -> /dev/null$' "$SQUASH_LIST" >/dev/null && ok 'legacy networking.service is durably masked' || bad 'networking.service mask missing from live root'
if grep -Eq '/home/spectre/.config/dconf/user$' "$SQUASH_LIST"; then
  bad 'mutable live-user dconf database leaked into ISO'
else
  ok 'live root excludes mutable spectre dconf database'
fi
if grep -Fq '/usr/share/gnome-shell/extensions/spectre-desktop-ux@spectre.os/' "$SQUASH_LIST"; then
  bad 'retired spectre-desktop-ux extension leaked into live filesystem'
else
  ok 'live filesystem excludes retired spectre-desktop-ux extension'
fi
unsquashfs -ll "$W/filesystem.squashfs" | grep -E 'etc/systemd/system/default.target -> .*/graphical.target' >/dev/null && ok 'live root default target is graphical.target' || bad 'live root default.target is not graphical.target'
unsquashfs -ll "$W/filesystem.squashfs" | grep -E '/usr/(sbin|bin)/gdm3?$' >/dev/null && ok 'GDM present in live root' || bad 'GDM missing from live root'
# Spectre 1.0 final is core-only: legacy personal applications must not be
# present in the Live filesystem. The managed-app framework may remain, but
# its default registry is empty and installs no application payload.
if unsquashfs -ll "$W/filesystem.squashfs" 2>/dev/null | grep -Eq '(/|^)(swiftshare|appsweep)(/|\.|$)|/opt/codedev/apps/(swiftshare|appsweep)(/|$)|personal-apps[.]manifest'; then
  bad 'legacy personal application artifact leaked into core-only live filesystem'
else
  ok 'core-only live filesystem contains no SwiftShare/AppSweep legacy payload'
fi
MANAGED_MANIFEST="$W/managed-apps.manifest"
unsquashfs -cat "$W/filesystem.squashfs" usr/share/spectre/managed-apps.manifest > "$MANAGED_MANIFEST" 2>/dev/null || bad 'managed-app registry manifest missing from live filesystem'
if grep -vE '^[[:space:]]*(#|$)' "$MANAGED_MANIFEST" | grep -q .; then
  bad 'Spectre 1.0 final managed-app registry is not empty'
else
  ok 'managed-app registry is present and empty by default'
fi
if unsquashfs -ll "$W/filesystem.squashfs" | grep -qiE '(^|/)conky([^/]*)(/|$)'; then
  bad 'legacy Conky fallback exists in live filesystem'
else
  ok 'live filesystem excludes legacy Conky fallback'
fi

# Verify the ISO really advertises both optical boot paths.
REPORT="$W/el-torito.txt"
xorriso -indev "$ISO" -report_el_torito plain > "$REPORT" 2>&1 || true
grep -Eq 'BIOS[[:space:]]+y' "$REPORT" && ok 'BIOS El Torito boot image present' || bad 'BIOS El Torito boot image missing'
grep -Eq 'UEFI[[:space:]]+y' "$REPORT" && ok 'UEFI El Torito boot image present' || bad 'UEFI El Torito boot image missing'

echo
printf '[ok] %s ISO live-boot, identity, product-boundary and firmware verification passed.\n' "$SPECTRE_PRETTY_NAME"
