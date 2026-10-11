#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/config/release.conf"
TARGET="${1:-}"
[[ -n "$TARGET" && -d "$TARGET/etc" ]] || {
  echo "usage: $0 /path/to/rootfs" >&2
  exit 2
}

sudo install -d -m 0755 "$TARGET/etc/dconf/db/gdm.d" "$TARGET/usr/share/pixmaps"
sudo install -d -m 1777 "$TARGET/tmp" "$TARGET/var/tmp"
sudo chmod 1777 "$TARGET/tmp" "$TARGET/var/tmp"
sudo install -d -m 0755 "$TARGET/var/lib/apt/lists/partial" "$TARGET/var/cache/apt/archives/partial"

# Spectre is Debian-based, but the operating-system identity exposed to users is Spectre OS.
#
# Debian base-files owns both os-release paths. Protect Spectre's vendor identity
# with local dpkg diversions so later base-files upgrades cannot overwrite it.
# Use --no-rename because base-files is part of the essential base system.
[[ -x "$TARGET/usr/bin/dpkg-divert" ]] || {
  echo "dpkg-divert is missing from target rootfs" >&2
  exit 1
}

spectre_divert_identity_path() {
  local path="$1"
  local diverted="$2"
  local owner
  local true_name

  owner="$(sudo chroot "$TARGET" /usr/bin/dpkg-divert --listpackage "$path" 2>/dev/null || true)"

  case "$owner" in
    LOCAL)
      true_name="$(sudo chroot "$TARGET" /usr/bin/dpkg-divert --truename "$path" 2>/dev/null || true)"
      if [[ "$true_name" != "$diverted" ]]; then
        echo "Unexpected local diversion for $path: expected=$diverted actual=${true_name:-unknown}" >&2
        exit 1
      fi
      ;;
    "")
      sudo chroot "$TARGET" /usr/bin/dpkg-divert \
        --local \
        --add \
        --no-rename \
        --divert "$diverted" \
        "$path"

      true_name="$(sudo chroot "$TARGET" /usr/bin/dpkg-divert --truename "$path" 2>/dev/null || true)"
      if [[ "$true_name" != "$diverted" ]]; then
        echo "Diversion verification failed for $path: expected=$diverted actual=${true_name:-unknown}" >&2
        exit 1
      fi
      ;;
    *)
      echo "Unexpected existing diversion for $path: $owner" >&2
      exit 1
      ;;
  esac
}

spectre_divert_identity_path /usr/lib/os-release /usr/lib/os-release.debian
spectre_divert_identity_path /etc/os-release     /etc/os-release.debian

# Preserve the Debian vendor copy once for diagnostics/recovery.
if [[ ! -e "$TARGET/usr/lib/os-release.debian" &&
      -e "$TARGET/usr/lib/os-release" ]]; then
  sudo cp -a     "$TARGET/usr/lib/os-release"     "$TARGET/usr/lib/os-release.debian"
fi

if [[ ! -e "$TARGET/etc/os-release.debian" &&
      ! -L "$TARGET/etc/os-release.debian" ]]; then
  sudo ln -s ../usr/lib/os-release.debian     "$TARGET/etc/os-release.debian"
fi

# /usr/lib/os-release is Spectre's canonical vendor identity.
# /etc/os-release is a relative compatibility symlink.
sudo rm -f "$TARGET/etc/os-release" "$TARGET/usr/lib/os-release"

cat <<OSR | sudo tee "$TARGET/usr/lib/os-release" >/dev/null
NAME="Spectre OS"
PRETTY_NAME="$SPECTRE_PRETTY_NAME"
ID=spectre
ID_LIKE=debian
VERSION_ID="$SPECTRE_VERSION_ID"
VERSION="$SPECTRE_DISPLAY_VERSION"
VERSION_CODENAME=$SPECTRE_CODENAME
BUILD_ID="$SPECTRE_BUILD_ID"
LOGO=spectre-logo
OSR

sudo chmod 0644 "$TARGET/usr/lib/os-release"
sudo ln -s ../usr/lib/os-release "$TARGET/etc/os-release"

cat <<LSB | sudo tee "$TARGET/etc/lsb-release" >/dev/null
DISTRIB_ID=Spectre
DISTRIB_RELEASE=$SPECTRE_VERSION_ID
DISTRIB_CODENAME=$SPECTRE_CODENAME
DISTRIB_DESCRIPTION="$SPECTRE_PRETTY_NAME"
LSB

cat <<ISSUE | sudo tee "$TARGET/etc/issue" >/dev/null
$SPECTRE_PRETTY_NAME \n \l
ISSUE
printf '%s\n' "$SPECTRE_PRETTY_NAME" | sudo tee "$TARGET/etc/issue.net" >/dev/null

# Ensure the greeter uses Spectre artwork and does not expose vendor/base branding.
if [[ -f "$TARGET/usr/share/pixmaps/spectre-gdm-logo.png" ]]; then
  :
elif [[ -f "$TARGET/usr/share/pixmaps/spectre-logo.png" ]]; then
  sudo cp "$TARGET/usr/share/pixmaps/spectre-logo.png" "$TARGET/usr/share/pixmaps/spectre-gdm-logo.png"
fi

cat <<'GDM' | sudo tee "$TARGET/etc/dconf/db/gdm.d/10-spectre-identity" >/dev/null
# Spectre OS greeter identity.
[org/gnome/shell]
enabled-extensions=@as []
disable-user-extensions=true

[org/gnome/desktop/interface]
color-scheme='prefer-dark'
accent-color='blue'

[org/gnome/login-screen]
logo='/usr/share/pixmaps/spectre-gdm-logo.png'
banner-message-enable=false
disable-user-list=false
GDM

# Remove old Spectre policy comments or values that still literally advertise the base release.
if [[ -d "$TARGET/etc/dconf/db/gdm.d" ]]; then
  while IFS= read -r -d '' f; do
    sudo sed -i \
      -e 's/Debian 13/Spectre OS/g' \
      -e 's/debian 13/Spectre OS/g' "$f" || true
  done < <(find "$TARGET/etc/dconf/db/gdm.d" -type f -print0)
fi

# User-facing GRUB distributor string.
if [[ -f "$TARGET/etc/default/grub" ]]; then
  if sudo grep -q '^GRUB_DISTRIBUTOR=' "$TARGET/etc/default/grub"; then
    sudo sed -i 's/^GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="Spectre OS"/' "$TARGET/etc/default/grub"
  else
    echo 'GRUB_DISTRIBUTOR="Spectre OS"' | sudo tee -a "$TARGET/etc/default/grub" >/dev/null
  fi
fi

if [[ -x "$TARGET/usr/bin/dconf" ]]; then
  sudo chroot "$TARGET" dconf update || true
fi

# Do not touch apt sources or package provenance. Spectre remains a Debian-based distribution.
