#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/config/release.conf"
TARGET="${SPECTRE_GNOME_ROOTFS:-$ROOT/rootfs-gnome}"
SUITE="${SPECTRE_GNOME_SUITE:-trixie}"
MIRROR="${SPECTRE_GNOME_MIRROR:-https://deb.debian.org/debian}"
SPECTRE_USER="${SPECTRE_USER:-spectre}"
SPECTRE_ROOTFS_ACCOUNT_MODE="${SPECTRE_ROOTFS_ACCOUNT_MODE:-live-template}"
SPECTRE_PASSWORD="${SPECTRE_PASSWORD:-}"
SPECTRE_LOCALE="${SPECTRE_LOCALE:-en_US.UTF-8}"
SPECTRE_TIMEZONE="${SPECTRE_TIMEZONE:-UTC}"

for cmd in debootstrap sudo chroot mount umount; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "Missing host command: $cmd" >&2
        exit 1
    }
done

if [[ -e "$TARGET/etc/os-release" ]]; then
    echo "Target already contains a rootfs: $TARGET" >&2
    echo "Move/remove it first if you want a clean rebuild." >&2
    exit 1
fi

mkdir -p "$TARGET"

echo "[1/9] Bootstrapping Debian $SUITE amd64 userspace for Spectre..."
sudo debootstrap --arch=amd64 "$SUITE" "$TARGET" "$MIRROR"

cleanup() {
    sudo umount -lf "$TARGET/dev/pts" 2>/dev/null || true
    sudo umount -lf "$TARGET/dev" 2>/dev/null || true
    sudo umount -lf "$TARGET/proc" 2>/dev/null || true
    sudo umount -lf "$TARGET/sys" 2>/dev/null || true
}
trap cleanup EXIT

sudo mount --bind /dev "$TARGET/dev"
sudo mount --bind /dev/pts "$TARGET/dev/pts"
sudo mount -t proc proc "$TARGET/proc"
sudo mount -t sysfs sysfs "$TARGET/sys"

cat <<EOF2 | sudo tee "$TARGET/etc/apt/sources.list" >/dev/null
deb $MIRROR $SUITE main contrib non-free-firmware
deb $MIRROR $SUITE-updates main contrib non-free-firmware
deb http://security.debian.org/debian-security $SUITE-security main contrib non-free-firmware
EOF2

echo "[2/9] Installing GNOME 48 desktop, Wayland stack and Spectre tools..."
sudo chroot "$TARGET" /bin/bash -eux <<'CHROOT'
export DEBIAN_FRONTEND=noninteractive
apt-get update

# task-gnome-desktop supplies a dependable Debian GNOME foundation. Spectre
# then retains an explicit daily-use core and removes the optional GNOME suite
# so the first app grid is deliberate instead of looking like an uncurated
# upstream installation.
apt-get install -y \
    systemd-sysv systemd-timesyncd dbus dbus-user-session \
    task-gnome-desktop gdm3 gnome-shell gnome-session gnome-control-center \
    gnome-terminal nautilus firefox-esr gnome-text-editor gnome-calculator \
    gnome-system-monitor file-roller loupe evince gnome-disk-utility \
    libreoffice-writer libreoffice-calc libreoffice-impress libreoffice-draw \
    libreoffice-math libreoffice-gnome libreoffice-gtk3 libreoffice-style-colibre \
    gnome-shell-extension-dashtodock \
    gnome-shell-extension-apps-menu \
    gnome-shell-extension-places-menu \
    gnome-shell-extension-user-theme \
    gnome-shell-extension-appindicator \
    gnome-shell-extension-desktop-icons-ng \
    network-manager network-manager-gnome \
    sudo locales ca-certificates curl wget git nano less bash-completion \
    iproute2 iputils-ping pciutils usbutils smartmontools nvme-cli acpi \
    libgl1-mesa-dri mesa-vulkan-drivers mesa-utils xwayland switcheroo-control \
    pipewire pipewire-pulse wireplumber \
    power-profiles-daemon bluez fwupd ufw apparmor apparmor-utils systemd-zram-generator \
    fonts-cantarell fonts-dejavu-core \
    papirus-icon-theme fastfetch \
    python3 python3-gi gir1.2-gtk-4.0 gir1.2-adw-1 \
    podman passt uidmap slirp4netns fuse-overlayfs \
    initramfs-tools grub-common grub-efi-amd64-bin dosfstools parted rsync \
    plymouth plymouth-themes \
    polkitd pkexec udisks2 gvfs-backends xdg-user-dirs xdg-utils

# These applications remain available for an optional productivity profile,
# but they are not part of the base operating-system image. Only purge a name
# when dpkg confirms it is installed so the list stays portable across Debian
# point releases.
optional_desktop_packages=(
    evolution evolution-common
    gnome-calendar gnome-characters gnome-clocks gnome-contacts
    gnome-maps gnome-music gnome-sound-recorder gnome-tour
    cheese shotwell simple-scan totem
    gnome-tweaks gnome-shell-extension-manager
)
installed_optional=()
for package in "${optional_desktop_packages[@]}"; do
    if dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null | grep -q '^ii'; then
        installed_optional+=("$package")
    fi
done
if ((${#installed_optional[@]})); then
    apt-get purge -y "${installed_optional[@]}"
fi

apt-get clean
rm -rf /var/lib/apt/lists/*
CHROOT

echo "[3/9] Configuring Spectre locale, timezone and machine identity..."

echo spectre | sudo tee "$TARGET/etc/hostname" >/dev/null
cat <<'EOF2' | sudo tee "$TARGET/etc/hosts" >/dev/null
127.0.0.1 localhost
127.0.1.1 spectre
::1       localhost ip6-localhost ip6-loopback
EOF2

# Locale generation.
sudo sed -i "s/^# *${SPECTRE_LOCALE//./\\.} UTF-8/${SPECTRE_LOCALE} UTF-8/" "$TARGET/etc/locale.gen" || true
if ! sudo grep -q "^${SPECTRE_LOCALE} UTF-8" "$TARGET/etc/locale.gen"; then
    echo "$SPECTRE_LOCALE UTF-8" | sudo tee -a "$TARGET/etc/locale.gen" >/dev/null
fi
sudo chroot "$TARGET" locale-gen
printf 'LANG=%s\n' "$SPECTRE_LOCALE" | sudo tee "$TARGET/etc/default/locale" >/dev/null

if [[ -e "$TARGET/usr/share/zoneinfo/$SPECTRE_TIMEZONE" ]]; then
    sudo ln -sfn "/usr/share/zoneinfo/$SPECTRE_TIMEZONE" "$TARGET/etc/localtime"
    echo "$SPECTRE_TIMEZONE" | sudo tee "$TARGET/etc/timezone" >/dev/null
fi

cat <<EOF2 | sudo tee "$TARGET/etc/spectre-release" >/dev/null
$SPECTRE_PRETTY_NAME
EOF2

cat <<EOF2 | sudo tee "$TARGET/etc/os-release" >/dev/null
NAME="Spectre OS"
PRETTY_NAME="$SPECTRE_PRETTY_NAME"
ID=spectre
ID_LIKE=debian
VERSION_ID="$SPECTRE_VERSION_ID"
VERSION="$SPECTRE_DISPLAY_VERSION"
VERSION_CODENAME=$SPECTRE_CODENAME
BUILD_ID="$SPECTRE_BUILD_ID"
LOGO=spectre-logo
EOF2

cat <<EOF2 | sudo tee "$TARGET/etc/issue" >/dev/null
$SPECTRE_PRETTY_NAME \n \l
EOF2

cat <<EOF2 | sudo tee "$TARGET/etc/motd" >/dev/null
$SPECTRE_PRETTY_NAME
Custom Spectre kernel + GNOME 48 / Wayland desktop
EOF2

echo "[4/9] Creating desktop user '$SPECTRE_USER'..."
if ! sudo chroot "$TARGET" id "$SPECTRE_USER" >/dev/null 2>&1; then
    sudo chroot "$TARGET" useradd -m -s /bin/bash "$SPECTRE_USER"
fi

for group in sudo video input audio render plugdev netdev; do
    if sudo chroot "$TARGET" getent group "$group" >/dev/null 2>&1; then
        sudo chroot "$TARGET" usermod -aG "$group" "$SPECTRE_USER"
    fi
done

case "$SPECTRE_ROOTFS_ACCOUNT_MODE" in
    live-template)
        # Production image construction must be unattended and must never bake a
        # reusable password into the build root.  The `spectre` account here is
        # a disposable live/QA account only.  The installer replaces it with
        # the owner's account and password before first installed boot.
        sudo chroot "$TARGET" passwd -d "$SPECTRE_USER" >/dev/null
        sudo install -d -m 0755 "$TARGET/etc/sudoers.d"
        cat <<'SUDOERS' | sudo tee "$TARGET/etc/sudoers.d/90-spectre-live" >/dev/null
# Spectre live/build-template account only. Removed by the installer.
spectre ALL=(ALL:ALL) NOPASSWD: ALL
SUDOERS
        sudo chmod 0440 "$TARGET/etc/sudoers.d/90-spectre-live"
        if [[ -d "$TARGET/etc/gdm3" ]]; then
            cat <<'GDM' | sudo tee "$TARGET/etc/gdm3/daemon.conf" >/dev/null
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=spectre
WaylandEnable=true
GDM
        fi
        echo "[Spectre] Configured disposable passwordless live/build account; installed credentials are created by the installer."
        ;;
    development)
        # Development-only escape hatch.  It remains non-interactive: callers
        # must explicitly provide a value rather than causing a hidden prompt.
        [[ -n "$SPECTRE_PASSWORD" ]] || {
            echo "[Spectre] ERROR: development account mode requires SPECTRE_PASSWORD; interactive password prompts are disabled." >&2
            exit 2
        }
        printf '%s:%s\n' "$SPECTRE_USER" "$SPECTRE_PASSWORD" | sudo chroot "$TARGET" chpasswd
        ;;
    *)
        echo "[Spectre] ERROR: unsupported SPECTRE_ROOTFS_ACCOUNT_MODE=$SPECTRE_ROOTFS_ACCOUNT_MODE" >&2
        exit 2
        ;;
esac

# Disable direct root password login; administrative work goes through sudo.
sudo chroot "$TARGET" passwd -l root || true

echo "[5/9] Preparing persistent-filesystem defaults..."
cat <<'EOF2' | sudo tee "$TARGET/etc/fstab" >/dev/null
LABEL=SPECTRE_ROOT  /         ext4  defaults,noatime  0  1
LABEL=SPECTRE_EFI   /boot/efi vfat  defaults,nofail,x-systemd.device-timeout=2s,umask=0077  0  2
EOF2

# A cloned build should receive a fresh machine identity on first boot.
sudo truncate -s 0 "$TARGET/etc/machine-id"
sudo rm -f "$TARGET/var/lib/dbus/machine-id"

echo "[6/9] Installing Spectre GNOME visual identity..."
SPECTRE_GNOME_ROOTFS="$TARGET" SPECTRE_USER="$SPECTRE_USER" \
    "$ROOT/profiles/gnome/install-branding.sh"

SPECTRE_GNOME_ROOTFS="$TARGET" SPECTRE_USER="$SPECTRE_USER" \
    "$ROOT/profiles/gnome/install-boot-branding.sh"

echo "[7/9] Enabling GNOME desktop services..."
sudo chroot "$TARGET" systemctl enable NetworkManager.service
sudo chroot "$TARGET" systemctl mask networking.service >/dev/null 2>&1 || true
sudo chroot "$TARGET" systemctl enable gdm3.service || true
sudo chroot "$TARGET" systemctl enable systemd-timesyncd.service || true
sudo chroot "$TARGET" systemctl enable switcheroo-control.service >/dev/null 2>&1 || true
sudo chroot "$TARGET" systemctl enable spectre-healthcheck.service || true
sudo chroot "$TARGET" systemctl set-default graphical.target || \
    sudo ln -sfn /lib/systemd/system/graphical.target "$TARGET/etc/systemd/system/default.target"

# GDM should prefer Wayland when the GPU stack supports it.
if [[ -f "$TARGET/etc/gdm3/daemon.conf" ]]; then
    sudo sed -i 's/^WaylandEnable=false/#WaylandEnable=false/' "$TARGET/etc/gdm3/daemon.conf" || true
fi

echo "[8/9] Applying user-home defaults..."
USER_HOME="$TARGET/home/$SPECTRE_USER"
if [[ -d "$USER_HOME" ]]; then
    uid="$(sudo chroot "$TARGET" id -u "$SPECTRE_USER")"
    gid="$(sudo chroot "$TARGET" id -g "$SPECTRE_USER")"
    sudo chown -R "$uid:$gid" "$USER_HOME"
fi

# Make the desktop feel complete on first login.
if sudo chroot "$TARGET" command -v xdg-user-dirs-update >/dev/null 2>&1; then
    sudo chroot "$TARGET" /bin/su -s /bin/sh - "$SPECTRE_USER" -c \
        'HOME="$HOME" /usr/bin/xdg-user-dirs-update' || true
fi

# Keep useful boot diagnostics across reboots while limiting growth.
sudo install -d "$TARGET/etc/systemd/journald.conf.d"
cat <<'EOF2' | sudo tee "$TARGET/etc/systemd/journald.conf.d/10-spectre.conf" >/dev/null
[Journal]
Storage=persistent
SystemMaxUse=256M
RuntimeMaxUse=64M
Compress=yes
EOF2

echo "[9/9] Final cleanup..."
sudo rm -rf "$TARGET/tmp"/* "$TARGET/var/tmp"/* 2>/dev/null || true
sudo chroot "$TARGET" ldconfig

cleanup
trap - EXIT

echo
echo "[ok] Spectre GNOME rootfs created at: $TARGET"
echo "     Desktop: GNOME / Wayland with Spectre Night styling"
echo "     User:    $SPECTRE_USER"
echo
echo "Next:"
echo "  ./profiles/gnome/make-disk-image.sh"
echo "  ./profiles/gnome/run-qemu.sh ~/linux-7.1.8/arch/x86/boot/bzImage"
