#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/config/release.conf"
IMAGE="${SPECTRE_UEFI_IMAGE:-$ROOT/iso/spectre-gnome-uefi.img}"

# SPECTRE_RECOVERY_RELEASE_PREFLIGHT_V1
if [[ -n "${SPECTRE_RECOVERY_ISO:-}" ]]; then
    [[ -f "$SPECTRE_RECOVERY_ISO" ]] || {
        echo "[FAIL] Missing recovery ISO: $SPECTRE_RECOVERY_ISO" >&2
        exit 1
    }
else
    [[ -f "$IMAGE" ]] || {
        echo "[FAIL] Missing UEFI image: $IMAGE" >&2
        exit 1
    }
fi
if pgrep -f '[q]emu-system-x86_64' >/dev/null 2>&1; then
  echo "[FAIL] QEMU is running. Shut down Spectre before release checks." >&2
  exit 2
fi

loop=""; mnt=""; recovery_tmp=""
cleanup() {
  set +e
  [[ -n "$mnt" ]] && sudo umount "$mnt" 2>/dev/null || true
  [[ -n "$mnt" ]] && rmdir "$mnt" 2>/dev/null || true
  [[ -n "$loop" ]] && sudo losetup -d "$loop" 2>/dev/null || true
  [[ -n "$recovery_tmp" ]] && rm -rf --one-file-system -- "$recovery_tmp" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# SPECTRE_RECOVERY_RELEASE_ROOTFS_V2
if [[ -n "${SPECTRE_RECOVERY_ISO:-}" ]]; then
  command -v xorriso >/dev/null 2>&1 || {
    echo "[FAIL] xorriso is required for recovery ISO release checks" >&2
    exit 1
  }

  recovery_tmp="$(mktemp -d "${TMPDIR:-/tmp}/spectre-release-check.XXXXXX")"
  recovery_sq="$recovery_tmp/filesystem.squashfs"

  printf '[Spectre] Inspecting recovery ISO live root...\n'

  xorriso     -osirrox on     -indev "$SPECTRE_RECOVERY_ISO"     -extract /live/filesystem.squashfs "$recovery_sq"     >/dev/null 2>&1 || {
      echo "[FAIL] Recovery ISO lacks readable /live/filesystem.squashfs" >&2
      exit 1
    }

  [[ -s "$recovery_sq" ]] || {
    echo "[FAIL] Extracted recovery SquashFS is empty" >&2
    exit 1
  }

  loop="$(sudo losetup --find --show --read-only "$recovery_sq")"
  mnt="$recovery_tmp/rootfs"
  mkdir "$mnt"

  sudo mount -o ro -t squashfs "$loop" "$mnt"

  printf '[OK]   recovery ISO SquashFS mounted read-only for release checks\n'
else
  printf '[Spectre] Inspecting legacy UEFI source image...\n'

  loop="$(sudo losetup --find --show --read-only --partscan "$IMAGE")"
  command -v udevadm >/dev/null 2>&1 && sudo udevadm settle || true
  part="${loop}p2"

  [[ -b "$part" ]] || {
    echo "[FAIL] Root partition missing: $part" >&2
    exit 1
  }

  mnt="$(mktemp -d)"
  sudo mount -o ro "$part" "$mnt"
fi

fail=0
ok(){ printf '[OK]   %s\n' "$*"; }
warn(){ printf '[WARN] %s\n' "$*"; }
bad(){ printf '[FAIL] %s\n' "$*"; fail=1; }

[[ -f "$mnt/etc/os-release" ]] && grep -q '^ID=spectre$' "$mnt/etc/os-release" && ok "Spectre OS identity" || bad "Spectre /etc/os-release identity"
grep -q '^PRETTY_NAME="Spectre OS' "$mnt/etc/os-release" 2>/dev/null && ok "Spectre user-facing OS name" || bad "Spectre PRETTY_NAME missing"
if grep -Fqx "PRETTY_NAME=\"$SPECTRE_PRETTY_NAME\"" "$mnt/etc/os-release" 2>/dev/null; then
  ok "Release identity matches config/release.conf"
elif [[ "${SPECTRE_ALLOW_PRODUCT_CLEANUP:-0}" == "1" ]]; then
  warn "Source image identity is stale and will be finalized in the staged rootfs"
else
  bad "Release identity drift"
fi
! grep -qi 'Debian 13' "$mnt/etc/os-release" "$mnt/etc/issue" "$mnt/etc/issue.net" 2>/dev/null && ok "No Debian 13 name in primary OS identity files" || bad "Debian 13 remains in primary OS identity files"

[[ -x "$mnt/usr/sbin/NetworkManager" ]] && ok "NetworkManager installed" || bad "NetworkManager missing"
[[ -x "$mnt/usr/sbin/gdm3" || -x "$mnt/usr/sbin/gdm" ]] && ok "GDM installed" || bad "GDM missing"
grep -q '^spectre:' "$mnt/etc/passwd" 2>/dev/null && ok "spectre account exists" || bad "spectre account missing"

shadow_line="$(sudo awk -F: '$1=="spectre"{print; exit}' "$mnt/etc/shadow" 2>/dev/null || true)"
if [[ -z "$shadow_line" ]]; then
  bad "spectre shadow entry missing"
else
  shadow_field="${shadow_line#*:}"
  shadow_field="${shadow_field%%:*}"
  if [[ -z "$shadow_field" ]]; then
    ok "spectre live template has no baked-in password"
  else
    bad "spectre live template unexpectedly contains a password or lock marker"
  fi
fi

for f in etc/pam.d/gdm-password etc/pam.d/common-auth etc/pam.d/common-account etc/pam.d/common-session; do
  [[ -s "$mnt/$f" ]] && ok "PAM: /$f" || bad "Missing PAM file: /$f"
done

mode_tmp="$(stat -c '%a' "$mnt/tmp" 2>/dev/null || true)"
[[ "$mode_tmp" == "1777" ]] && ok "/tmp permissions 1777" || bad "/tmp missing or wrong mode ($mode_tmp)"
mode_run="$(stat -c '%a' "$mnt/run" 2>/dev/null || true)"
[[ "$mode_run" == "755" ]] && ok "/run mount point present" || bad "/run missing or wrong mode ($mode_run)"

if grep -Rqi 'Debian 13' "$mnt/etc/dconf/db/gdm.d" 2>/dev/null; then
  bad "Debian 13 still appears in GDM source policy"
else
  ok "GDM policy has no Debian 13 label"
fi

[[ -f "$mnt/usr/share/plymouth/themes/spectre/spectre.script" ]] && ok "Spectre Plymouth theme" || bad "Spectre Plymouth theme missing"
find "$mnt/usr/share/backgrounds" -maxdepth 3 -type f -iname '*spectre*' -print -quit 2>/dev/null | grep -q . && ok "Spectre wallpapers" || bad "Spectre wallpapers missing"
[[ -f "$ROOT/profiles/gnome/installer/spectre-installer" ]] && ok "Spectre graphical installer source" || bad "Installer source missing"

kernel="$(find "$mnt/boot" -maxdepth 1 -type f -name 'vmlinuz-*' | sort | tail -1 || true)"
[[ -n "$kernel" ]] && ok "Kernel present: ${kernel##*/}" || bad "Kernel missing"
if [[ -n "$kernel" ]]; then
  krel="${kernel##*/vmlinuz-}"
  [[ -f "$mnt/boot/initrd.img-$krel" ]] && ok "Matching initramfs" || bad "Matching initramfs missing"
  cfg="$mnt/boot/config-$krel"
  if [[ -f "$cfg" ]]; then
    for opt in CONFIG_BLK_DEV_LOOP CONFIG_SQUASHFS CONFIG_OVERLAY_FS CONFIG_ISO9660_FS; do
      grep -Eq "^${opt}=(y|m)$" "$cfg" && ok "Installer ISO kernel support: $opt" || bad "Kernel lacks $opt"
    done
  fi
fi

stale_app="$(find "$mnt/opt" "$mnt/usr/local" "$mnt/usr/bin" "$mnt/usr/share/applications" \
    "$mnt/etc/systemd" "$mnt/etc/xdg" "$mnt/home/spectre" \
    -maxdepth 8 \( -iname '*swiftshare*' -o -iname '*appsweep*' \) -print -quit 2>/dev/null || true)"
if [[ -n "$stale_app" ]]; then
  if [[ "${SPECTRE_ALLOW_PRODUCT_CLEANUP:-0}" == "1" ]]; then
    warn "stale personal app exists in engineering image and will be removed for the core-only production image: $stale_app"
  else
    bad "ambient personal app exists in the core-only production source/image: $stale_app"
  fi
else
  ok "engineering source image contains no ambient personal-app payload"
fi

printf '\n'
if [[ "$fail" == 0 ]]; then
  echo "[ok] Spectre installer-release preflight passed."
else
  echo "[FAIL] Blocking release issues remain." >&2
  exit 1
fi
