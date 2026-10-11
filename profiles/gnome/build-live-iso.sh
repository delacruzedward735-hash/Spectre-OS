#!/usr/bin/env bash
set -euo pipefail


# SPECTRE_GDM_LOCKSCREEN_HOST_TOOLS_V1 BEGIN
# GNOME Shell's GDM wallpaper is a compiled GResource. Fail before a long ISO
# build if the host cannot deterministically rebuild that resource.
for _spectre_gdm_tool in gresource glib-compile-resources; do
    command -v "$_spectre_gdm_tool" >/dev/null 2>&1 || {
        echo "[Spectre] Missing host command: $_spectre_gdm_tool" >&2
        echo "[Spectre] On Zorin/Ubuntu install: sudo apt install libglib2.0-dev-bin" >&2
        exit 1
    }
done
# SPECTRE_GDM_LOCKSCREEN_HOST_TOOLS_V1 END


ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/config/release.conf"
IMAGE="${SPECTRE_UEFI_IMAGE:-$ROOT/iso/spectre-gnome-uefi.img}"
RECOVERY_ISO="${SPECTRE_RECOVERY_ISO:-}"
SOURCE_SNAPSHOT="${RECOVERY_ISO:-$IMAGE}"
OUTPUT="${SPECTRE_ISO_OUTPUT:-$ROOT/iso/$SPECTRE_ISO_FILENAME}"
WORK="${SPECTRE_ISO_WORKDIR:-$ROOT/build/installer-iso}"
KEEP="${SPECTRE_KEEP_ISO_WORK:-0}"
REUSE_SQUASHFS="${SPECTRE_REUSE_SQUASHFS:-0}"
SPECTRE_SUDO_KEEPALIVE_PID=""

start_host_privilege_session() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    return 0
  fi
  echo "[Spectre] Host privilege is required for ISO assembly. Authenticate once; the build keeps the sudo session alive."
  sudo -v || { echo "[Spectre] ERROR: host privilege authentication failed." >&2; exit 1; }
  (
    while kill -0 "$$" 2>/dev/null; do
      sleep 45
      sudo -n -v >/dev/null 2>&1 || exit 0
    done
  ) &
  SPECTRE_SUDO_KEEPALIVE_PID=$!
}

stop_host_privilege_session() {
  if [[ -n "${SPECTRE_SUDO_KEEPALIVE_PID:-}" ]]; then
    kill "$SPECTRE_SUDO_KEEPALIVE_PID" 2>/dev/null || true
    wait "$SPECTRE_SUDO_KEEPALIVE_PID" 2>/dev/null || true
    SPECTRE_SUDO_KEEPALIVE_PID=""
  fi
}

[[ "$REUSE_SQUASHFS" != "1" ]] || {
  echo "[Spectre] Refusing stale SquashFS reuse: desktop and product-boundary changes would be skipped." >&2
  echo "[Spectre] Run the normal build so product-boundary cleanup and current branding enter the ISO." >&2
  exit 2
}

if [[ -n "$RECOVERY_ISO" ]]; then
  [[ -z "${SPECTRE_UEFI_IMAGE:-}" ]] || {
    echo '[Spectre] ERROR: set either SPECTRE_RECOVERY_ISO or SPECTRE_UEFI_IMAGE, not both.' >&2
    exit 2
  }
  [[ -f "$RECOVERY_ISO" ]] || {
    echo "[Spectre] ERROR: recovery ISO missing: $RECOVERY_ISO" >&2
    exit 1
  }
  printf '[Spectre] RC1 ISO recovery source selected: %s\n' "$RECOVERY_ISO"
else
  [[ -f "$IMAGE" ]] || {
    echo "[Spectre] Missing source image: $IMAGE" >&2
    exit 1
  }
fi
# SPECTRE_VERIFIED_ISO_MODULE_BRIDGE_V1: refuse accidental old-module ISO builds.
[[ -n "${SPECTRE_OPTIMIZED_MODULES:-}" ]] || {
  echo '[Spectre] ERROR: this source requires explicit SPECTRE_OPTIMIZED_MODULES.' >&2
  echo '[Spectre] Do not run the legacy builder while module artifacts are missing.' >&2
  exit 2
}
[[ -d "$SPECTRE_OPTIMIZED_MODULES/kernel" ]] || {
  echo '[Spectre] ERROR: optimized module candidate missing.' >&2; exit 2;
}
# Linux truncates /proc/PID/comm to 15 characters, so pgrep -x can never
# reliably match the longer qemu-system-x86_64 name. Match the full command
# line and use the bracket form so pgrep does not match its own invocation.
pgrep -f '[q]emu-system-x86_64' >/dev/null 2>&1 && { echo "[Spectre] Shut down QEMU before building the ISO." >&2; exit 2; }

for cmd in sudo losetup mount umount mountpoint findmnt rsync chroot mksquashfs unsquashfs mformat mcopy mdir grub-mkrescue xorriso sha256sum lsinitramfs unmkinitramfs python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "[Spectre] Missing host command: $cmd" >&2; exit 1; }
done

start_host_privilege_session

SPECTRE_ALLOW_PRODUCT_CLEANUP=1 "$ROOT/profiles/gnome/release-check.sh"

# Production build workdirs contain root-owned files because the live filesystem
# is assembled with rsync/chroot under sudo.  An interrupted build can therefore
# leave a root-owned $WORK behind.  Never try to remove it as the desktop user.
# More importantly, never recursively delete it until every stale bind/proc/sysfs
# mount below it has been detached; otherwise a leftover /dev bind mount could
# make a recursive cleanup cross into the host filesystem.
safe_work_prefix="$ROOT/build/"
case "$WORK/" in
  "$safe_work_prefix"*) ;;
  *)
    echo "[Spectre] ERROR: refusing privileged cleanup outside $safe_work_prefix: $WORK" >&2
    exit 2
    ;;
esac

unmount_work_mounts() {
  local target
  # Deepest mount first. findmnt is authoritative even after a previous build
  # was killed before this script could run its EXIT trap.
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    echo "[Spectre] Detaching stale build mount: $target"
    sudo umount -lf -- "$target" || {
      echo "[Spectre] ERROR: could not detach stale build mount: $target" >&2
      return 1
    }
  done < <(
    findmnt -rn -o TARGET |
      awk -v root="$WORK" '$0 == root || index($0, root "/") == 1 { print length($0) " " $0 }' |
      sort -rn | cut -d' ' -f2-
  )

  if findmnt -rn -o TARGET | awk -v root="$WORK" '$0 == root || index($0, root "/") == 1 { found=1 } END { exit(found ? 0 : 1) }'; then
    echo "[Spectre] ERROR: a mount is still active below $WORK; refusing recursive deletion." >&2
    findmnt -rn -o TARGET,SOURCE,FSTYPE | awk -v root="$WORK" '$1 == root || index($1, root "/") == 1' >&2 || true
    return 1
  fi
}

reset_workdir() {
  sudo -v
  if [[ -e "$WORK" ]]; then
    unmount_work_mounts
    echo "[Spectre] Removing previous privileged ISO workdir: $WORK"
    sudo rm -rf --one-file-system -- "$WORK"
  fi
  mkdir -p "$WORK/rootfs" "$WORK/iso/live" "$WORK/iso/boot/grub" "$(dirname "$OUTPUT")"
}

reset_workdir
STAGE="$WORK/rootfs"; ISO_ROOT="$WORK/iso"
loop=""; src=""; dev=0; pts=0; proc=0; sys=0

# RC5.6 ownership invariant: the filesystem hierarchy itself is system-owned.
# Never recursively chown the image (service/user-owned files are legitimate);
# only normalize top-level hierarchy nodes that must not belong to UID 1000.
normalize_system_root_ownership() {
  local path
  sudo chown root:root "$STAGE"
  sudo chmod 0755 "$STAGE"
  for path in bin boot dev etc home lib lib64 media mnt opt proc root run sbin srv sys tmp usr var; do
    if [[ -e "$STAGE/$path" || -L "$STAGE/$path" ]]; then
      sudo chown -h root:root "$STAGE/$path"
    fi
  done
}

verify_system_root_ownership() {
  local uid gid mode
  uid="$(stat -c %u "$STAGE")"
  gid="$(stat -c %g "$STAGE")"
  mode="$(stat -c %a "$STAGE")"
  [[ "$uid" == 0 && "$gid" == 0 && "$mode" == 755 ]] || {
    echo "[Spectre] ERROR: staged live root ownership/mode is ${uid}:${gid} ${mode}; expected 0:0 755." >&2
    exit 1
  }
  printf '[OK]   staged live filesystem root is root:root mode 0755\n'
}
cleanup(){
  set +e
  stop_host_privilege_session
  [[ "$pts" == 1 ]] && sudo umount -lf "$STAGE/dev/pts" 2>/dev/null || true
  [[ "$dev" == 1 ]] && sudo umount -lf "$STAGE/dev" 2>/dev/null || true
  [[ "$proc" == 1 ]] && sudo umount -lf "$STAGE/proc" 2>/dev/null || true
  [[ "$sys" == 1 ]] && sudo umount -lf "$STAGE/sys" 2>/dev/null || true
  [[ -n "$src" ]] && sudo umount -lf "$src" 2>/dev/null || true
  [[ -n "$src" ]] && rmdir "$src" 2>/dev/null || true
  [[ -n "$loop" ]] && sudo losetup -d "$loop" 2>/dev/null || true
  # Also catch mounts inherited from an earlier interrupted build.  Do this
  # before recursive deletion so cleanup cannot cross a stale bind mount.
  unmount_work_mounts >/dev/null 2>&1 || true
  [[ "$KEEP" != 1 ]] && sudo rm -rf --one-file-system -- "$WORK" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

if [[ -n "$RECOVERY_ISO" ]]; then
  printf '[Spectre] Recovering qualified RC1 live root from trusted ISO...\n'

  RECOVERY_SQUASHFS="$WORK/rc1-recovery-filesystem.squashfs"

  rm -f -- "$RECOVERY_SQUASHFS"

  xorriso \
    -osirrox on \
    -indev "$RECOVERY_ISO" \
    -extract /live/filesystem.squashfs "$RECOVERY_SQUASHFS"

  [[ -s "$RECOVERY_SQUASHFS" ]] || {
    echo '[Spectre] ERROR: trusted recovery SquashFS extraction failed.' >&2
    exit 1
  }

  sudo unsquashfs \
    -f \
    -no-progress \
    -d "$STAGE" \
    "$RECOVERY_SQUASHFS" >/dev/null

  rm -f -- "$RECOVERY_SQUASHFS"

  [[ -d "$STAGE/etc" && -d "$STAGE/usr" && -d "$STAGE/boot" ]] || {
    echo '[Spectre] ERROR: recovered RC1 live root is incomplete.' >&2
    exit 1
  }

  printf '[PASS] Trusted RC1 SquashFS recovered into disposable staging.\n'
else
  printf '[Spectre] Capturing current working Spectre image...\n'
  loop="$(sudo losetup --find --show --read-only --partscan "$IMAGE")"
  command -v udevadm >/dev/null 2>&1 && sudo udevadm settle || true
  part="${loop}p2"; [[ -b "$part" ]] || { echo "Root partition missing: $part" >&2; exit 1; }
  src="$(mktemp -d)"; sudo mount -o ro "$part" "$src"
  sudo rsync -aHAX --numeric-ids \
    --exclude='/boot/efi/***' --exclude='/run/***' --exclude='/tmp/***' --exclude='/var/tmp/***' \
    "$src/" "$STAGE/"
  sudo umount "$src"; rmdir "$src"; src=""; sudo losetup -d "$loop"; loop=""
fi

# The captured engineering image may have acquired UID 1000 ownership on /.
# Correct it before any chrooted package postinst runs, preventing systemd's
# unsafe-path warnings and preventing that ownership from entering SquashFS.
normalize_system_root_ownership
verify_system_root_ownership

sudo install -d -m 0755 "$STAGE/run" "$STAGE/run/lock"
sudo install -d -m 1777 "$STAGE/tmp" "$STAGE/var/tmp"
sudo chmod 1777 "$STAGE/tmp" "$STAGE/var/tmp"
sudo install -d -m 0755 "$STAGE/var/lib/apt/lists/partial" "$STAGE/var/cache/apt/archives/partial"

"$ROOT/profiles/gnome/finalize-spectre-identity.sh" "$STAGE"

kernel="$(find "$STAGE/boot" -maxdepth 1 -type f -name 'vmlinuz-*' | sort | tail -1 || true)"
[[ -n "$kernel" ]] || { echo "[Spectre] Kernel missing in captured image." >&2; exit 1; }
krel="${kernel##*/vmlinuz-}"
[[ -f "$STAGE/boot/initrd.img-$krel" ]] || { echo "[Spectre] initramfs missing." >&2; exit 1; }
# SPECTRE_VERIFIED_ISO_MODULE_BRIDGE_V1: only the disposable ISO-stage root is edited.
"$ROOT/profiles/gnome/verified-module-stage.sh" "$STAGE" "$krel" "$SPECTRE_OPTIMIZED_MODULES"

printf '[Spectre] Installing Debian live-boot backend + graphical installer dependencies...\n'
sudo mkdir -p "$STAGE/dev/pts" "$STAGE/proc" "$STAGE/sys"
sudo mount --bind /dev "$STAGE/dev"; dev=1
sudo mount --bind /dev/pts "$STAGE/dev/pts"; pts=1
sudo mount -t proc proc "$STAGE/proc"; proc=1
sudo mount -t sysfs sysfs "$STAGE/sys"; sys=1
sudo rm -f "$STAGE/etc/resolv.conf"; sudo cp -L /etc/resolv.conf "$STAGE/etc/resolv.conf"

sudo chroot "$STAGE" /bin/bash -euc '
install -d -m 1777 /tmp /var/tmp
install -d -m 0755 /var/lib/apt/lists/partial /var/cache/apt/archives/partial
export DEBIAN_FRONTEND=noninteractive
apt-get update
# Do not install live-tools here: it diverts update-initramfs and is not
# required to boot the installer media.
apt-get install -y --no-install-recommends \
  live-boot live-boot-initramfs-tools live-config live-config-systemd busybox \
  zenity python3 python3-venv python3-tk python3-gi gir1.2-gtk-4.0 gir1.2-adw-1 podman passt uidmap slirp4netns fuse-overlayfs locales os-prober ntfs-3g \
  gnome-shell-extension-desktop-icons-ng \
  libreoffice-writer libreoffice-calc libreoffice-impress libreoffice-draw \
  libreoffice-math libreoffice-gnome libreoffice-gtk3 libreoffice-style-colibre \
  power-profiles-daemon bluez fwupd ufw apparmor apparmor-utils systemd-zram-generator \
  pciutils usbutils mesa-utils smartmontools nvme-cli acpi switcheroo-control \
  parted dosfstools e2fsprogs rsync util-linux \
  grub2-common grub-efi-amd64-bin grub-pc-bin efibootmgr \
  firmware-intel-graphics firmware-intel-misc firmware-iwlwifi firmware-realtek \
  firmware-atheros firmware-brcm80211 firmware-mediatek firmware-libertas \
  firmware-amd-graphics firmware-nvidia-graphics firmware-misc-nonfree \
  firmware-sof-signed intel-microcode amd64-microcode
systemctl set-default graphical.target
systemctl enable NetworkManager.service >/dev/null 2>&1 || true
systemctl enable gdm3.service >/dev/null 2>&1 || systemctl enable gdm.service >/dev/null 2>&1 || true
systemctl enable switcheroo-control.service >/dev/null 2>&1 || true
# NetworkManager is Spectre's single network owner. Mask Debian's legacy
# ifupdown unit: disabling alone still allowed it to start in live-boot QA.
systemctl mask networking.service >/dev/null 2>&1 || true

test -x /usr/share/initramfs-tools/scripts/live
test -f /usr/share/initramfs-tools/hooks/live
test -x /usr/bin/live-boot
test -d /usr/lib/live/boot

apt-get clean
rm -rf /var/lib/apt/lists/*
install -d -m 0755 /var/lib/apt/lists/partial
'

# The working disk can be older than the source tree. Reinstall the current
# Spectre runtime into the staged live root before SquashFS capture. This is the
# source-of-truth boundary that prevents Polish/UI changes from being skipped.
printf '[Spectre] Synchronizing current Spectre source into staged live root...\n'
"$ROOT/profiles/gnome/sync-runtime-root.sh" "$STAGE" live

printf '[Spectre] Enforcing Spectre 1.0 core-only application policy...\n'
printf '[Spectre] Installing empty-by-default managed application registry...\n'
"$ROOT/profiles/gnome/personal-apps/install-managed-apps.sh" "$STAGE"
RUNTIME_SOURCE_HASH="$("$ROOT/profiles/gnome/runtime-source-hash.sh")"

# v0.8.9c: Debian live-boot's initramfs hook can independently call
# auto_add_modules net. MODULES=list only disables mkinitramfs' default
# module classes; it does not prevent hook scripts from adding their own
# module classes. For Spectre's LOCAL optical/USB installer this early
# network-driver sweep is unnecessary: networking is available normally
# after switch-root from the full SquashFS root. Temporarily disable only
# that one broad hook action while generating the live initramfs, then
# restore the packaged hook before SquashFS capture.
LIVE_HOOK="$STAGE/usr/share/initramfs-tools/hooks/live"
LIVE_HOOK_BACKUP="$WORK/live-hook.original"
[[ -f "$LIVE_HOOK" ]] || { echo '[Spectre] ERROR: Debian live-boot initramfs hook is missing.' >&2; exit 1; }
sudo cp -a "$LIVE_HOOK" "$LIVE_HOOK_BACKUP"
if grep -Eq '^[[:space:]]*auto_add_modules[[:space:]]+net([[:space:]]*)$' "$LIVE_HOOK"; then
  sudo sed -Ei 's/^([[:space:]]*)auto_add_modules[[:space:]]+net([[:space:]]*)$/\1# Spectre local-media initramfs: broad network module sweep disabled\2/' "$LIVE_HOOK"
  printf '[OK]   disabled live-boot auto_add_modules net for local-media initramfs build\n'
else
  echo '[Spectre] ERROR: expected auto_add_modules net line was not found in Debian live-boot hook; refusing an unverified patch.' >&2
  grep -nE 'auto_add_modules|devices|network' "$LIVE_HOOK" | tail -40 >&2 || true
  exit 1
fi
! grep -Eq '^[[:space:]]*auto_add_modules[[:space:]]+net([[:space:]]*)$' "$LIVE_HOOK" || { echo '[Spectre] ERROR: live-boot network sweep is still active.' >&2; exit 1; }

# Force the essential live-boot entry point/components into the generated
# initramfs. This is intentionally redundant with Debian's package hook: it
# makes this custom-kernel build deterministic and verifiable.
cat <<'HOOK' | sudo tee "$STAGE/etc/initramfs-tools/hooks/zz-spectre-live" >/dev/null
#!/bin/sh
set -e
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "${1:-}" in prereqs) prereqs; exit 0;; esac
. /usr/share/initramfs-tools/hook-functions
install -d -m 0755 "$DESTDIR/scripts" "$DESTDIR/usr/bin" "$DESTDIR/usr/lib/live/boot"
install -m 0755 /usr/share/initramfs-tools/scripts/live "$DESTDIR/scripts/live"
copy_exec /usr/bin/live-boot /usr/bin/live-boot
cp -a /usr/lib/live/boot/. "$DESTDIR/usr/lib/live/boot/"
HOOK
sudo chmod 0755 "$STAGE/etc/initramfs-tools/hooks/zz-spectre-live"


# v0.8.4: do NOT replace /init or /bin/sh ourselves.
# Debian initramfs-tools already installs the primary /init and its BusyBox shell.
# The v0.8.3 late hook could create a path that existed in lsinitramfs but was
# not executable by the kernel, causing fallback to BusyBox init (/etc/init.d/rcS).
sudo rm -f "$STAGE/etc/initramfs-tools/hooks/zz-spectre-init"
sudo rm -f "$STAGE/etc/initramfs-tools/conf.d/00-spectre-live-init"

printf '[Spectre] Installing Spectre graphical installer into live image...\n'
sudo install -d "$STAGE/usr/local/sbin" "$STAGE/usr/local/bin" "$STAGE/usr/share/applications" "$STAGE/etc/polkit-1/rules.d" "$STAGE/etc/xdg/autostart"
sudo install -m 0755 "$ROOT/profiles/gnome/installer/spectre-installer" "$STAGE/usr/local/sbin/spectre-installer"
sudo install -m 0755 "$ROOT/profiles/gnome/installer/spectre-installer-backend" "$STAGE/usr/local/sbin/spectre-installer-backend"
sudo install -m 0755 "$ROOT/profiles/gnome/installer/spectre-installer-launcher" "$STAGE/usr/local/bin/spectre-installer-launcher"
sudo install -m 0755 "$ROOT/profiles/gnome/installer/spectre-live-installer-setup" "$STAGE/usr/local/bin/spectre-live-installer-setup"
sudo install -m 0644 "$ROOT/profiles/gnome/installer/com.spectre.Installer.desktop" "$STAGE/usr/share/applications/com.spectre.Installer.desktop"
sudo install -d "$STAGE/usr/share/pixmaps"
sudo install -m 0644 "$ROOT/profiles/gnome/installer/assets/spectre-installer.png" "$STAGE/usr/share/pixmaps/spectre-installer.png"
for icon_size in 48 64 128 256 512; do
  sudo install -d "$STAGE/usr/share/icons/hicolor/${icon_size}x${icon_size}/apps"
  sudo install -m 0644 "$ROOT/profiles/gnome/installer/icons/${icon_size}x${icon_size}/apps/spectre-installer.png" \
    "$STAGE/usr/share/icons/hicolor/${icon_size}x${icon_size}/apps/spectre-installer.png"
done
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  sudo gtk-update-icon-cache -f -t "$STAGE/usr/share/icons/hicolor" >/dev/null 2>&1 || true
fi
sudo install -m 0644 "$ROOT/profiles/gnome/installer/spectre-live-installer.desktop" "$STAGE/etc/xdg/autostart/spectre-live-installer.desktop"
sudo install -m 0644 "$ROOT/profiles/gnome/installer/49-spectre-installer.rules" "$STAGE/etc/polkit-1/rules.d/49-spectre-installer.rules"

if [[ -d "$STAGE/etc/gdm3" ]]; then
  cat <<'GDM' | sudo tee "$STAGE/etc/gdm3/daemon.conf" >/dev/null
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=spectre
WaylandEnable=true
GDM
fi

# Release live-media policy: the disposable live account has no password and
# never asks for one. The real installed account is created later by the
# installer and still requires the password chosen by the owner.
sudo chroot "$STAGE" passwd -d spectre >/dev/null 2>&1 || {
  echo '[Spectre] ERROR: could not remove the live-session password.' >&2
  exit 1
}
sudo install -d -m 0755 "$STAGE/etc/sudoers.d"
cat <<'SUDOERS' | sudo tee "$STAGE/etc/sudoers.d/90-spectre-live" >/dev/null
# Spectre live USB/ISO only. Removed by the installer before first installed boot.
spectre ALL=(ALL:ALL) NOPASSWD: ALL
SUDOERS
sudo chmod 0440 "$STAGE/etc/sudoers.d/90-spectre-live"

cat <<'FSTAB' | sudo tee "$STAGE/etc/fstab" >/dev/null
# Spectre OS live media. live-boot supplies the root filesystem.
FSTAB
sudo mkdir -p "$STAGE/etc/live/config.conf.d"
cat <<'LIVE' | sudo tee "$STAGE/etc/live/config.conf.d/10-spectre.conf" >/dev/null
LIVE_HOSTNAME="spectre-live"
LIVE_USERNAME="spectre"
LIVE_CONFIG_CMDLINE="username=spectre hostname=spectre-live"
LIVE

mods="$STAGE/etc/initramfs-tools/modules"
sudo install -d -m 0755 "$(dirname "$mods")"
# v0.8.9b: the captured disk image can carry a stale modules list from older
# experimental builds. MODULES=list ALWAYS includes every line in this file,
# so appending to it causes the live initramfs to grow on every rebuild. Reset
# it before selecting the small, explicit live-media set below.
OLD_MODULE_LINES="$(sudo awk '!/^[[:space:]]*(#|$)/{n++} END{print n+0}' "$mods" 2>/dev/null || echo 0)"
sudo truncate -s 0 "$mods"
printf '# Spectre live ISO: deterministic compact early-boot module set.\n' | sudo tee "$mods" >/dev/null
printf '[Spectre] Reset stale initramfs module list (%s previous entries removed).\n' "$OLD_MODULE_LINES"
KCFG="$STAGE/boot/config-$krel"

# MODULES=list keeps the initramfs compact.  Modules built as =m must be listed,
# while drivers built directly into the kernel (=y) must NOT be rejected merely
# because no .ko file exists.  CONFIG_SCSI_VIRTIO=y is a valid example.
kcfg_state() {
  local sym="$1"
  [[ -f "$KCFG" ]] || { printf 'unknown'; return 0; }
  if grep -q "^${sym}=y$" "$KCFG"; then printf 'y';
  elif grep -q "^${sym}=m$" "$KCFG"; then printf 'm';
  else printf 'n'; fi
}

add_if_module() {
  local mod="$1"
  if sudo chroot "$STAGE" /bin/bash -c "modinfo -k '$krel' '$mod' >/dev/null 2>&1"; then
    sudo grep -qxF "$mod" "$mods" || echo "$mod" | sudo tee -a "$mods" >/dev/null
  fi
}

for mod in \
  loop squashfs overlay isofs \
  scsi_mod sd_mod sr_mod cdrom \
  ahci libahci libata ata_piix \
  usb_storage uas xhci_pci xhci_hcd ehci_pci ehci_hcd ohci_pci ohci_hcd uhci_hcd \
  nvme \
  virtio_blk virtio_pci virtio_scsi \
  ttm drm_ttm_helper drm_vram_helper vmwgfx vboxvideo \
  bochs virtio_gpu; do
  add_if_module "$mod"
done

# SPECTRE_VBOX_EARLY_KMS_V1
for mod in ttm drm_ttm_helper drm_vram_helper vmwgfx vboxvideo; do
  sudo chroot "$STAGE" /bin/bash -c "modinfo -k '$krel' '$mod' >/dev/null 2>&1" || {
    echo "[Spectre] ERROR: required VirtualBox early-display module is unavailable: $mod ($krel)." >&2
    exit 1
  }
  sudo grep -qxF "$mod" "$mods" || {
    echo "[Spectre] ERROR: required VirtualBox early-display module was not selected: $mod." >&2
    exit 1
  }
done
printf '[OK]   VirtualBox VMSVGA/VBoxSVGA early-KMS module set selected\n'

require_capability() {
  local mod="$1" sym="$2" label="$3" state
  state="$(kcfg_state "$sym")"
  case "$state" in
    y)
      printf '[OK]   %s built into kernel (%s=y)\n' "$label" "$sym"
      ;;
    m)
      sudo chroot "$STAGE" /bin/bash -c "modinfo -k '$krel' '$mod' >/dev/null 2>&1" || {
        echo "[Spectre] ERROR: $label is configured as a module but modinfo cannot find $mod for $krel." >&2
        exit 1
      }
      sudo grep -qxF "$mod" "$mods" || echo "$mod" | sudo tee -a "$mods" >/dev/null
      printf '[OK]   %s selected for initramfs (%s=m)\n' "$label" "$sym"
      ;;
    *)
      echo "[Spectre] ERROR: required live-boot capability is disabled: $label ($sym)." >&2
      exit 1
      ;;
  esac
}

require_capability isofs       CONFIG_ISO9660_FS   'ISO9660 filesystem'
require_capability overlay     CONFIG_OVERLAY_FS   'overlay filesystem'
require_capability virtio_scsi CONFIG_SCSI_VIRTIO  'VirtIO-SCSI'
require_capability sr_mod      CONFIG_BLK_DEV_SR    'SCSI CD-ROM'
require_capability cdrom       CONFIG_CDROM         'generic CD-ROM core'
printf '[OK]   required live-media capabilities validated for %s\n' "$krel"
SELECTED_MODULE_LINES="$(sudo awk '!/^[[:space:]]*(#|$)/{n++} END{print n+0}' "$mods")"
printf '[OK]   compact initramfs module list contains %s explicit entries\n' "$SELECTED_MODULE_LINES"
[[ "$SELECTED_MODULE_LINES" -le 40 ]] || {
  echo "[Spectre] ERROR: initramfs module list unexpectedly contains $SELECTED_MODULE_LINES entries; refusing a bloated live initramfs." >&2
  exit 1
}

# v0.8.5: the installed Spectre disk image boots with the compact initramfs,
# while Debian's live build regenerates initramfs using its own compressor.
# A custom kernel may not have every RD decompressor enabled.  Force gzip,
# which is the most portable initramfs format and is supported by Spectre's
# known-working boot path.
cat <<'ICFG' | sudo tee "$STAGE/etc/initramfs-tools/conf.d/99-spectre-iso" >/dev/null
MODULES=list
BUSYBOX=y
COMPRESS=gzip
COMPRESSLEVEL=6
ICFG

if [[ -f "$KCFG" ]]; then
  if grep -qE '^CONFIG_SATA_AHCI=(y|m)$' "$KCFG"; then
    printf '[OK]   kernel has SATA/AHCI boot-media support\n'
  else
    echo '[Spectre] WARN: CONFIG_SATA_AHCI is not enabled; QEMU optical compatibility may rely on another storage driver.'
  fi
  grep -q '^CONFIG_RD_GZIP=y$' "$KCFG" || {
    echo '[Spectre] ERROR: custom kernel lacks CONFIG_RD_GZIP=y; cannot publish a gzip initramfs.' >&2
    exit 1
  }
  printf '[OK]   kernel supports gzip initramfs decompression\n'
else
  echo "[Spectre] WARN: $KCFG is missing; gzip support cannot be checked from the saved kernel config."
fi

printf '[Spectre] Checking Debian initramfs primary init source...\n'
sudo chroot "$STAGE" /bin/bash -euc '
test -x /usr/share/initramfs-tools/init
head -n1 /usr/share/initramfs-tools/init | grep -qx "#!/bin/sh"
command -v busybox >/dev/null
'

printf '[Spectre] Rebuilding live initramfs for %s...\n' "$krel"
# live-tools is intentionally absent, therefore this is the genuine
# initramfs-tools updater. Use verbose mode to make failures diagnosable.
sudo chroot "$STAGE" /usr/sbin/update-initramfs -u -k "$krel" -v

# Restore Debian packaged hook so the captured/installed Spectre root is not
# permanently modified by the local-media initramfs optimization.
sudo cp -a "$LIVE_HOOK_BACKUP" "$LIVE_HOOK"
printf '[OK]   restored Debian live-boot hook after initramfs generation\n'

printf '[Spectre] Verifying live-boot files inside initramfs...\n'

# Confirm the generated archive actually contains a gzip-compressed main
# initramfs.  Offline unmkinitramfs can decode formats that the custom kernel
# itself may not support, so this check is separate from the content checks.
python3 - "$STAGE/boot/initrd.img-$krel" <<'PYC'
import sys
p=sys.argv[1]
data=open(p,'rb').read()
magics={
    'gzip': b'\x1f\x8b\x08',
    'zstd': b'\x28\xb5\x2f\xfd',
    'xz': b'\xfd7zXZ\x00',
    'bzip2': b'BZh',
    'lz4': b'\x04\x22\x4d\x18',
}
hits=[(data.find(m),name) for name,m in magics.items() if data.find(m)>=0]
if not hits:
    print('[Spectre] ERROR: no recognized compressed initramfs payload found', file=sys.stderr)
    sys.exit(1)
pos,name=min(hits)
print(f'[Spectre] Initramfs compressed payload: {name} at offset {pos}')
if name != 'gzip':
    print('[Spectre] ERROR: live initramfs is not gzip; refusing ISO because the custom kernel boot compatibility is unproven.', file=sys.stderr)
    sys.exit(1)
print('[OK]   live initramfs compression is gzip')
PYC

INIT_LIST="$WORK/initramfs.list"
lsinitramfs "$STAGE/boot/initrd.img-$krel" > "$INIT_LIST"
if ! grep -Eq '(^|/)scripts/live$' "$INIT_LIST"; then
  echo '[Spectre] ERROR: /scripts/live is still absent after the forced Spectre live hook.' >&2
  echo '[Spectre] Relevant initramfs entries:' >&2
  grep -E '(^|/)(scripts|usr/lib/live|usr/bin/live-boot|bin/live-boot)' "$INIT_LIST" | tail -80 >&2 || true
  echo '[Spectre] Rebuild with SPECTRE_KEEP_ISO_WORK=1 if deeper inspection is needed.' >&2
  exit 1
fi
grep -Eq '(^|/)(usr/)?bin/live-boot$' "$INIT_LIST" || { echo '[Spectre] ERROR: live-boot executable missing from initramfs.' >&2; exit 1; }
grep -Eq '(^|/)usr/lib/live/boot/9990-main\.sh$' "$INIT_LIST" || { echo '[Spectre] ERROR: live-boot components missing from initramfs.' >&2; exit 1; }
grep -Eq '(^|/)init$' "$INIT_LIST" || { echo '[Spectre] ERROR: primary /init is missing from initramfs.' >&2; exit 1; }
grep -Eq '(^|/)bin/sh$' "$INIT_LIST" || { echo '[Spectre] ERROR: /bin/sh is missing from initramfs.' >&2; exit 1; }
grep -Eq '(^|/)(usr/)?bin/busybox$' "$INIT_LIST" || { echo '[Spectre] ERROR: busybox is missing from initramfs.' >&2; exit 1; }
printf '[OK]   /scripts/live embedded\n'
printf '[OK]   live-boot executable embedded\n'
printf '[OK]   live-boot components embedded\n'
printf '[OK]   primary /init embedded\n'
printf '[OK]   /bin/sh interpreter embedded\n'
printf '[OK]   busybox embedded\n'

# v0.8.9a: verify required capabilities correctly for both kernel built-ins (=y)
# and loadable modules (=m).  A built-in driver has no .ko by design.
verify_capability_in_initramfs() {
  local sym="$1" regex="$2" label="$3" state
  state="$(kcfg_state "$sym")"
  case "$state" in
    y) printf '[OK]   %s built into kernel; no .ko required\n' "$label" ;;
    m)
      grep -Eq "$regex" "$INIT_LIST" || {
        echo "[Spectre] ERROR: $label is =m but its .ko is missing from live initramfs." >&2
        exit 1
      }
      printf '[OK]   %s module embedded in live initramfs\n' "$label"
      ;;
    *) echo "[Spectre] ERROR: $label is disabled in kernel config." >&2; exit 1 ;;
  esac
}
verify_capability_in_initramfs CONFIG_ISO9660_FS  '(^|/)lib/modules/.*/kernel/fs/isofs/isofs\.ko(\..*)?$' 'ISO9660/isofs'
verify_capability_in_initramfs CONFIG_OVERLAY_FS  '(^|/)lib/modules/.*/kernel/fs/overlayfs/overlay\.ko(\..*)?$' 'overlayfs'
verify_capability_in_initramfs CONFIG_SCSI_VIRTIO '(^|/)lib/modules/.*/kernel/drivers/scsi/virtio_scsi\.ko(\..*)?$' 'VirtIO-SCSI'

# A filename in lsinitramfs is not enough: prove that the kernel's /init
# interpreter chain is actually executable.  This directly catches the failure
# that produced BusyBox rcS fallback and "No working init found".
printf '[Spectre] Executing initramfs shell smoke test...\n'
INIT_EXTRACT="$WORK/initramfs-extract"
sudo rm -rf "$INIT_EXTRACT"
sudo mkdir -p "$INIT_EXTRACT"
sudo unmkinitramfs "$STAGE/boot/initrd.img-$krel" "$INIT_EXTRACT" >/dev/null
if [[ -f "$INIT_EXTRACT/main/init" ]]; then
  INIT_ROOT="$INIT_EXTRACT/main"
elif [[ -f "$INIT_EXTRACT/init" ]]; then
  INIT_ROOT="$INIT_EXTRACT"
else
  echo '[Spectre] ERROR: extracted initramfs contains no root /init.' >&2
  find "$INIT_EXTRACT" -maxdepth 3 -name init -o -name sh 2>/dev/null | head -40 >&2 || true
  exit 1
fi
# SPECTRE_INITRAMFS_CANONICAL_ROOT_V26
# ~/spectre is a symlink into /mnt/spectre-dev. Canonicalize INIT_ROOT
# before comparing it with readlink -f results so equivalent paths do
# not fail the containment test merely because one path traversed a symlink.
INIT_ROOT="$(sudo readlink -f "$INIT_ROOT" 2>/dev/null || true)"
[[ -n "$INIT_ROOT" && -d "$INIT_ROOT" ]] || {
  echo "[Spectre] ERROR: canonical initramfs root is unavailable." >&2
  exit 1
}

sudo test -f "$INIT_ROOT/init" || { echo '[Spectre] ERROR: /init is not a regular file.' >&2; exit 1; }
sudo test -x "$INIT_ROOT/init" || { echo '[Spectre] ERROR: /init is not executable.' >&2; exit 1; }
[[ "$(sudo head -n1 "$INIT_ROOT/init")" == '#!/bin/sh' ]] || { echo '[Spectre] ERROR: unexpected /init interpreter.' >&2; exit 1; }
sudo test -e "$INIT_ROOT/bin/sh" || { echo '[Spectre] ERROR: /bin/sh missing after extraction.' >&2; exit 1; }
SHELL_TARGET="$(sudo readlink -f "$INIT_ROOT/bin/sh" 2>/dev/null || true)"

# SPECTRE_INITRAMFS_SHELLCHECK_V25
# unmkinitramfs creates a root-owned extraction tree. Validate its
# canonical shell target using the same privilege boundary instead
# of using the invoking user's Bash -x filesystem test.
#
# Security gates retained:
#   1. canonical target must exist,
#   2. canonical target must stay inside INIT_ROOT,
#   3. target must be a root-executable regular file,
#   4. /bin/sh must actually execute inside the initramfs chroot.

if [[ -z "$SHELL_TARGET" || "$SHELL_TARGET" != "$INIT_ROOT"/* ]]; then
  echo "[Spectre] ERROR: /bin/sh target is broken or outside initramfs: $SHELL_TARGET" >&2
  exit 1
fi

sudo test -f "$SHELL_TARGET" || {
  echo "[Spectre] ERROR: /bin/sh target is not a regular file: $SHELL_TARGET" >&2
  sudo stat "$SHELL_TARGET" 2>/dev/null >&2 || true
  exit 1
}

sudo test -x "$SHELL_TARGET" || {
  echo "[Spectre] ERROR: /bin/sh target is not root-executable: $SHELL_TARGET" >&2
  sudo stat -Lc "mode=%A octal=%a uid=%u gid=%g file=%n" "$SHELL_TARGET" 2>/dev/null >&2 || true
  exit 1
}

printf '[Spectre] /bin/sh canonical target: %s\n' "$SHELL_TARGET"
sudo chroot "$INIT_ROOT" /bin/sh -c 'printf SPECTRE_INITRAMFS_SHELL_OK' | grep -qx 'SPECTRE_INITRAMFS_SHELL_OK' || {
  echo '[Spectre] ERROR: /bin/sh cannot execute inside the extracted initramfs.' >&2
  exit 1
}
printf '[OK]   /init is a regular executable script\n'
printf '[OK]   /bin/sh symlink resolves inside initramfs\n'
printf '[OK]   /bin/sh executes successfully in initramfs chroot\n'
INITRD_COMPRESSED_BYTES="$(stat -c %s "$STAGE/boot/initrd.img-$krel")"
INITRD_UNPACKED_BYTES="$(sudo du -sb "$INIT_EXTRACT" | awk '{print $1}')"
INITRD_MODULE_COUNT="$(grep -Ec '(^|/)lib/modules/.*/.*\.ko(\..*)?$' "$INIT_LIST" || true)"
INITRD_NET_MODULE_COUNT="$(grep -Ec '(^|/)lib/modules/.*/kernel/drivers/net/.*\.ko(\..*)?$' "$INIT_LIST" || true)"
printf '[Spectre] Initramfs footprint: compressed=%s MiB, extracted=%s MiB, modules=%s, net-modules=%s\n' \
  "$(( (INITRD_COMPRESSED_BYTES + 1048575) / 1048576 ))" \
  "$(( (INITRD_UNPACKED_BYTES + 1048575) / 1048576 ))" \
  "$INITRD_MODULE_COUNT" "$INITRD_NET_MODULE_COUNT"
# A multi-gigabyte early userspace cannot safely fit in the default tmpfs rootfs
# of a 6 GiB VM. Keep a generous 1 GiB ceiling so accidental module-tree bloat
# is caught before ISO publication.
# The v0.8.9b failure had 373 modules because the live hook re-added a
# broad network class after MODULES=list processing. Local-media builds should
# now remain far below that. Keep a generous ceiling to catch regressions.
if (( INITRD_MODULE_COUNT > 180 )); then
  echo "[Spectre] ERROR: live initramfs still contains $INITRD_MODULE_COUNT kernel modules; live-hook bloat remains." >&2
  exit 1
fi
printf '[OK]   initramfs module count is below 180-module safety ceiling\n'
MAX_INITRAMFS_UNPACKED=$((1024 * 1024 * 1024))
if (( INITRD_UNPACKED_BYTES > MAX_INITRAMFS_UNPACKED )); then
  echo '[Spectre] ERROR: live initramfs expands beyond 1 GiB; refusing ISO to prevent kernel unpack write errors.' >&2
  exit 1
fi
printf '[OK]   initramfs extracted footprint is below 1 GiB safety ceiling\n'

[[ "$(readlink -f "$STAGE/etc/systemd/system/default.target" 2>/dev/null || true)" == */graphical.target ]] || {
  echo '[Spectre] ERROR: live root default target is not graphical.target.' >&2
  exit 1
}

[[ -d "$STAGE/run" ]] || {
  echo '[Spectre] ERROR: /run mount point is missing from the staged live root.' >&2
  exit 1
}
sudo chmod 0755 "$STAGE/run"

sudo truncate -s 0 "$STAGE/etc/machine-id" || true
sudo rm -f "$STAGE/var/lib/dbus/machine-id" || true
sudo find "$STAGE/var/log" -type f -exec truncate -s 0 {} \; 2>/dev/null || true

sudo umount "$STAGE/dev/pts"; pts=0
sudo umount "$STAGE/dev"; dev=0
sudo umount "$STAGE/proc"; proc=0
sudo umount "$STAGE/sys"; sys=0

"$ROOT/profiles/gnome/verify-product-boundaries.sh" "$STAGE"
# SPECTRE_VERIFIED_ISO_MODULE_BRIDGE_V1: package/install hooks must not replace verified .ko bytes.
if [[ -n "$RECOVERY_ISO" ]]; then
  sudo python3 "$ROOT/profiles/gnome/audit-rc1-recovery.py" \
    --mode integrated \
    --candidate "$SPECTRE_OPTIMIZED_MODULES" \
    --target "$STAGE" \
    --recovery-iso "$RECOVERY_ISO" \
    --krel "$krel"
else
  sudo python3 "$ROOT/profiles/gnome/audit-module-bridge.py" \
    --mode integrated --candidate "$SPECTRE_OPTIMIZED_MODULES" \
    --baseline "$ROOT/rootfs-gnome" --target "$STAGE" --krel "$krel"
fi

# Re-assert the root ownership boundary after all branding/package hooks.
normalize_system_root_ownership
verify_system_root_ownership

# SPECTRE_ROOTLESS_SUBIDS_BEGIN — installer-safe persistent rootless Podman configuration
[[ -d "$STAGE/etc" ]] || { echo "[STOP] Spectre stage root unavailable" >&2; exit 1; }
sudo bash "$(dirname "${BASH_SOURCE[0]}")/rootless-podman/install-into-rootfs.sh" "$STAGE"
# SPECTRE_ROOTLESS_SUBIDS_END
# SPECTRE_VBOX_RC86_BEGIN — vendor-proven VirtualBox display userspace
sudo python3 "$(dirname "${BASH_SOURCE[0]}")/virtualbox-guest/install-into-rootfs.py" stage --root "$STAGE" --archive "$(dirname "${BASH_SOURCE[0]}")/virtualbox-guest/Spectre-VM-GuestAdditions-7.0.16-verified.tar.gz" --proof "$(dirname "${BASH_SOURCE[0]}")/virtualbox-guest/Spectre-VM-GuestAdditions-7.0.16-verified.tar.json"
# SPECTRE_VBOX_RC86_END
# SquashFS/XZ can consume substantial memory when mksquashfs automatically
# uses every host CPU.  Spectre is routinely built on developer laptops with
# ~6 GiB RAM, so bound compression parallelism instead of allowing an 8+ worker
# fan-out that can trigger the host OOM killer.  Advanced builders may override
# the limits explicitly, but the defaults stay conservative and deterministic.
host_mem_mib="$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo 2>/dev/null || echo 0)"
host_swap_mib="$(awk '/^SwapTotal:/ {print int($2 / 1024)}' /proc/meminfo 2>/dev/null || echo 0)"
if [[ -n "${SPECTRE_SQUASHFS_PROCESSORS:-}" ]]; then
  squash_processors="$SPECTRE_SQUASHFS_PROCESSORS"
elif (( host_mem_mib > 0 && host_mem_mib < 4500 )); then
  squash_processors=1
elif (( host_mem_mib > 0 && host_mem_mib < 9000 )); then
  squash_processors=2
elif (( host_mem_mib > 0 && host_mem_mib < 16000 )); then
  squash_processors=3
else
  squash_processors=4
fi
[[ "$squash_processors" =~ ^[1-9][0-9]*$ ]] || {
  echo '[Spectre] ERROR: SPECTRE_SQUASHFS_PROCESSORS must be a positive integer.' >&2
  exit 2
}

if [[ -n "${SPECTRE_SQUASHFS_MEM:-}" ]]; then
  squash_mem="$SPECTRE_SQUASHFS_MEM"
elif (( host_mem_mib > 0 && host_mem_mib < 4500 )); then
  squash_mem=640M
elif (( host_mem_mib > 0 && host_mem_mib < 9000 )); then
  squash_mem=1024M
elif (( host_mem_mib > 0 && host_mem_mib < 16000 )); then
  squash_mem=1536M
else
  squash_mem=2048M
fi

printf '[Spectre] Compressing live filesystem (host RAM=%s MiB swap=%s MiB, workers=%s, memory cap=%s)...\n' \
  "$host_mem_mib" "$host_swap_mib" "$squash_processors" "$squash_mem"

squash_common=(
  "$STAGE" "$ISO_ROOT/live/filesystem.squashfs"
  -comp xz -b 1M -Xdict-size 1M -noappend
  -processors "$squash_processors"
  -wildcards -e 'boot/efi/*' 'var/cache/apt/archives/*' 'tmp/*' 'var/tmp/*'
)
# Newer squashfs-tools can impose an explicit compressor memory ceiling.
# Probe rather than assuming so Spectre remains buildable on older hosts too.
squash_help="$(mksquashfs -help 2>&1 || true)"
if grep -q -- '-mem ' <<<"$squash_help"; then
  squash_common+=( -mem "$squash_mem" )
fi

sudo rm -f "$ISO_ROOT/live/filesystem.squashfs"
set +e
sudo mksquashfs "${squash_common[@]}"
squash_rc=$?
set -e

# Exit 137 means SIGKILL.  On build hosts this is commonly the OOM killer.
# Retry exactly once with one worker and a smaller memory ceiling rather than
# throwing away the already prepared live root and making the user rebuild it.
if [[ "$squash_rc" -eq 137 ]]; then
  echo '[Spectre] WARNING: mksquashfs was SIGKILLed (likely host memory pressure).' >&2
  echo '[Spectre] Retrying SquashFS compression with one worker.' >&2
  sudo rm -f "$ISO_ROOT/live/filesystem.squashfs"
  retry_args=(
    "$STAGE" "$ISO_ROOT/live/filesystem.squashfs"
    -comp xz -b 1M -Xdict-size 1M -noappend
    -processors 1
    -wildcards -e 'boot/efi/*' 'var/cache/apt/archives/*' 'tmp/*' 'var/tmp/*'
  )
  if grep -q -- '-mem ' <<<"$squash_help"; then
    retry_args+=( -mem 640M )
  fi
  sudo mksquashfs "${retry_args[@]}"
  squash_rc=$?
fi
[[ "$squash_rc" -eq 0 ]] || {
  echo "[Spectre] ERROR: SquashFS compression failed with exit code $squash_rc." >&2
  echo '[Spectre] Check host memory/swap with: free -h; swapon --show' >&2
  exit "$squash_rc"
}

# Verify the immutable payload itself, not only the staging directory.
# Locate the immutable SquashFS root entry explicitly; do not depend on tool preamble formatting.
SQUASH_ROOT_META="$(unsquashfs -ll "$ISO_ROOT/live/filesystem.squashfs" 2>/dev/null | grep -m1 -E 'squashfs-root$' || true)"
if [[ ! "$SQUASH_ROOT_META" =~ ^d[rwx-]{9}[[:space:]]+root/root[[:space:]] ]]; then
  echo '[Spectre] ERROR: final SquashFS root is not owned by root:root.' >&2
  echo "[Spectre] SquashFS root metadata: ${SQUASH_ROOT_META:-unavailable}" >&2
  exit 1
fi
printf '[OK]   final SquashFS root ownership is root:root\n'
# SPECTRE_VERIFIED_ISO_MODULE_BRIDGE_V1: verify actual SquashFS, not just staging.
"$ROOT/profiles/gnome/verify-packaged-modules.sh"   "$ISO_ROOT/live/filesystem.squashfs" "$STAGE" "$krel" "$SPECTRE_OPTIMIZED_MODULES"

sudo du -sx --block-size=1 "$STAGE" | awk '{print $1}' | sudo tee "$ISO_ROOT/live/filesystem.size" >/dev/null
sudo cp "$STAGE/boot/vmlinuz-$krel" "$ISO_ROOT/live/vmlinuz"
sudo cp "$STAGE/boot/initrd.img-$krel" "$ISO_ROOT/live/initrd.img"
[[ -f "$KCFG" ]] && sudo cp "$KCFG" "$ISO_ROOT/live/kernel.config"

cat <<GRUB | sudo tee "$ISO_ROOT/boot/grub/grub.cfg" >/dev/null
set default=0
set timeout=6
if loadfont /boot/grub/fonts/unicode.pf2; then
  set gfxmode=auto
  insmod all_video
  terminal_output gfxterm
fi
menuentry 'Try or Install $SPECTRE_PRETTY_NAME' --class spectre --class gnu-linux {
  linux /live/vmlinuz rootfstype=ramfs rdinit=/init boot=live components live-media-path=/live live-media-timeout=30 username=spectre hostname=spectre-live systemd.unit=graphical.target quiet splash loglevel=3 systemd.show_status=false rd.systemd.show_status=false udev.log_level=3 vt.global_cursor_default=0 plymouth.ignore-serial-consoles console=tty0
  initrd /live/initrd.img
}
menuentry '$SPECTRE_PRETTY_NAME - QEMU optical compatibility' --class spectre --class gnu-linux {
  linux /live/vmlinuz rootfstype=ramfs rdinit=/init boot=live components live-media=/dev/sr0 live-media-path=/live live-media-timeout=30 username=spectre hostname=spectre-live systemd.unit=graphical.target quiet splash loglevel=4 console=ttyS0,115200 console=tty0
  initrd /live/initrd.img
}
menuentry '$SPECTRE_PRETTY_NAME - Safe graphics' --class spectre --class gnu-linux {
  linux /live/vmlinuz rootfstype=ramfs rdinit=/init boot=live components live-media-path=/live live-media-timeout=30 username=spectre hostname=spectre-live nomodeset plymouth.enable=0 systemd.unit=graphical.target loglevel=4 console=ttyS0,115200 console=tty0
  initrd /live/initrd.img
}
menuentry '$SPECTRE_PRETTY_NAME - Text diagnostics' --class spectre --class gnu-linux {
  linux /live/vmlinuz rootfstype=ramfs rdinit=/init boot=live components live-media-path=/live live-media-timeout=30 systemd.unit=multi-user.target console=ttyS0,115200 console=tty0 loglevel=6
  initrd /live/initrd.img
}
menuentry '$SPECTRE_PRETTY_NAME - Initramfs diagnostics' --class spectre --class gnu-linux {
  linux /live/vmlinuz rootfstype=ramfs rdinit=/init boot=live components live-media-path=/live live-media-timeout=30 break=mount debug=vc console=ttyS0,115200 console=tty0 loglevel=7
  initrd /live/initrd.img
}
GRUB

# SPECTRE_GRUB_MEDIA_DISCOVERY_RC6
# Physical USB/Ventoy/optical boot uses Debian live-boot media discovery.
# Only the explicitly named QEMU compatibility entry pins /dev/sr0.
GRUB_CFG="$ISO_ROOT/boot/grub/grub.cfg"
python3 - "$GRUB_CFG" "$SPECTRE_PRETTY_NAME" <<'PYGRUB'
from pathlib import Path
import re, sys
text = Path(sys.argv[1]).read_text()
entries = {}
for match in re.finditer(r"menuentry '([^']+)'[^\{]*\{(.*?)\n\}", text, re.S):
    entries[match.group(1)] = match.group(2)

def linux_line(block):
    for line in block.splitlines():
        if line.strip().startswith('linux /live/vmlinuz'):
            return line.strip()
    return ''

def require(cond, msg):
    if not cond:
        raise SystemExit('[FAIL] ' + msg)

def general(name):
    line = linux_line(entries.get(name, ''))
    require(line, f'missing GRUB linux line: {name}')
    require('boot=live' in line and 'live-media-path=/live' in line, f'live-boot contract missing: {name}')
    require('live-media-timeout=30' in line, f'physical media timeout is not 30s: {name}')
    require('live-media=' not in line, f'general boot entry hardcodes a media device: {name}')

pretty = sys.argv[2]
general(f'Try or Install {pretty}')
general(f'{pretty} - Safe graphics')
general(f'{pretty} - Text diagnostics')
general(f'{pretty} - Initramfs diagnostics')
qemu = linux_line(entries.get(f'{pretty} - QEMU optical compatibility', ''))
require(qemu, 'missing QEMU optical compatibility entry')
require('live-media=/dev/sr0' in qemu, 'QEMU compatibility entry lost /dev/sr0')
require('live-media-timeout=30' in qemu, 'QEMU compatibility media timeout is not 30s')
require('live-media-timeout=1' not in text, 'obsolete one-second media timeout remains')
print('[OK]   general Live entries use automatic media discovery')
print('[OK]   QEMU optical compatibility remains pinned to /dev/sr0')
PYGRUB

printf '[Spectre] Creating BIOS/UEFI installable ISO...\n'
rm -f "$OUTPUT" "$OUTPUT.sha256" "$OUTPUT.source-sha256" "$OUTPUT.manifest.txt" "$OUTPUT.boot-report.txt"
sudo grub-mkrescue -o "$OUTPUT" "$ISO_ROOT"
sudo chown "$(id -u):$(id -g)" "$OUTPUT"
xorriso -indev "$OUTPUT" -report_el_torito plain -report_system_area plain > "$OUTPUT.boot-report.txt" 2>&1 || true
sha256sum "$OUTPUT" > "$OUTPUT.sha256"
printf '%s  runtime-source\n' "$RUNTIME_SOURCE_HASH" > "$OUTPUT.source-sha256"
cat > "$OUTPUT.manifest.txt" <<EOF2
$SPECTRE_PRETTY_NAME
Built: $(date -Is)
Source snapshot: $SOURCE_SNAPSHOT
Runtime source SHA256: $RUNTIME_SOURCE_HASH
Build ID: $SPECTRE_BUILD_ID
Kernel: $krel
Architecture: amd64
Desktop: GNOME
Installer: Spectre Installer RC4.6 (guided installer + runtime safety + premium progress UX)
Boot: BIOS + UEFI via GRUB rescue ISO
Live root: /live/filesystem.squashfs
Product profile: Spectre core OS only (no bundled CodeDev/personal applications)
EOF2

printf '\n[ok] Installable %s ISO created:\n' "$SPECTRE_PRETTY_NAME"
ls -lh "$OUTPUT"
echo "SHA-256: $OUTPUT.sha256"
echo "Runtime source: $OUTPUT.source-sha256"
echo "Manifest: $OUTPUT.manifest.txt"
echo "Verify: ./profiles/gnome/verify-live-iso.sh"
echo "Test:   ./profiles/gnome/run-qemu-iso.sh"

[[ "$KEEP" != 1 ]] && sudo rm -rf "$WORK"
trap - EXIT INT TERM
