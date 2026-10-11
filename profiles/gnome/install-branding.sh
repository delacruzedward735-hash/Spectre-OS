#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TARGET="${SPECTRE_GNOME_ROOTFS:-$ROOT/rootfs-gnome}"
BRANDING="$ROOT/profiles/gnome/branding"
SPECTRE_USER="${SPECTRE_USER:-spectre}"

[[ -d "$TARGET/etc" ]] || {
    echo "GNOME rootfs not found: $TARGET" >&2
    echo "Run profiles/gnome/create-rootfs.sh first." >&2
    exit 1
}

for cmd in sudo cp install chroot python3; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "Missing host command: $cmd" >&2
        exit 1
    }
done

[[ -f "$BRANDING/backgrounds/spectre-gnome.png" ]] || {
    echo "Missing Spectre wallpaper assets." >&2
    exit 1
}

echo "[Spectre] Installing GNOME branding into $TARGET"

sudo install -d \
    "$TARGET/usr/share/backgrounds/spectre" \
    "$TARGET/usr/share/backgrounds/spectre/collection" \
    "$TARGET/usr/share/gnome-background-properties" \
    "$TARGET/usr/share/themes" \
    "$TARGET/usr/share/gnome-shell/extensions" \
    "$TARGET/usr/share/glib-2.0/schemas" \
    "$TARGET/usr/share/pixmaps" \
    "$TARGET/usr/share/plymouth/themes/spectre" \
    "$TARGET/usr/share/spectre" \
    "$TARGET/usr/share/applications" \
    "$TARGET/usr/local/bin" \
    "$TARGET/usr/local/sbin" \
    "$TARGET/etc/systemd/system" \
    "$TARGET/etc/systemd/journald.conf.d" \
    "$TARGET/etc/modprobe.d" \
    "$TARGET/etc/grub.d" \
    "$TARGET/etc/ufw" \
    "$TARGET/etc/xdg/autostart" \
    "$TARGET/etc/dconf/profile" \
    "$TARGET/etc/dconf/db/local.d" \
    "$TARGET/etc/dconf/db/gdm.d" \
    "$TARGET/var/lib/AccountsService/icons" \
    "$TARGET/var/lib/AccountsService/users" \
    "$TARGET/run" \
    "$TARGET/run/lock"

sudo chmod 0755 "$TARGET/run" "$TARGET/run/lock"

# NetworkManager owns networking in Spectre. A disabled legacy ifupdown unit
# was still pulled into the tested live boot, so enforce a durable mask in every
# branded root (including roots captured from older engineering images).
sudo rm -f "$TARGET/etc/systemd/system/networking.service"
sudo ln -s /dev/null "$TARGET/etc/systemd/system/networking.service"

# QEMU can expose the legacy PC speaker twice to newer custom kernels. It is
# not needed by the desktop and otherwise emits a distracting red boot error.
cat <<'MODPROBE' | sudo tee "$TARGET/etc/modprobe.d/spectre-quiet.conf" >/dev/null
# Spectre desktop quiet-boot policy.
blacklist pcspkr
MODPROBE

sudo install -m 0644 \
    "$BRANDING/backgrounds/spectre-gnome.png" \
    "$TARGET/usr/share/backgrounds/spectre/spectre-gnome.png"
sudo cp -a "$BRANDING/backgrounds/collection/." \
    "$TARGET/usr/share/backgrounds/spectre/collection/"
sudo find "$TARGET/usr/share/backgrounds/spectre/collection" -type f -exec chmod 0644 {} +
sudo install -m 0644 \
    "$BRANDING/backgrounds/spectre.xml" \
    "$TARGET/usr/share/gnome-background-properties/spectre.xml"

# Keep GNOME's neutral backgrounds, but remove Debian-branded wallpaper
# catalog entries so Appearance presents Spectre as the product identity.
sudo find "$TARGET/usr/share/gnome-background-properties" -maxdepth 1 -type f \
    \( -iname '*debian*.xml' -o -iname 'desktop-base*.xml' \) -delete 2>/dev/null || true

sudo rm -rf "$TARGET/usr/share/themes/Spectre-Night" "$TARGET/usr/share/themes/Spectre-Day"
sudo cp -a "$BRANDING/themes/Spectre-Night" "$TARGET/usr/share/themes/Spectre-Night"
sudo cp -a "$BRANDING/themes/Spectre-Day" "$TARGET/usr/share/themes/Spectre-Day"

sudo rm -rf "$TARGET/usr/share/gnome-shell/extensions/spectre-panel@spectre.os"
sudo cp -a "$BRANDING/extensions/spectre-panel@spectre.os" \
    "$TARGET/usr/share/gnome-shell/extensions/spectre-panel@spectre.os"

sudo rm -rf "$TARGET/usr/share/gnome-shell/extensions/spectre-hud@spectre.os"
sudo cp -a "$BRANDING/extensions/spectre-hud@spectre.os" \
    "$TARGET/usr/share/gnome-shell/extensions/spectre-hud@spectre.os"

sudo rm -rf "$TARGET/usr/share/gnome-shell/extensions/spectre-desktop-menu@spectre.os"
sudo cp -a "$BRANDING/extensions/spectre-desktop-menu@spectre.os" \
    "$TARGET/usr/share/gnome-shell/extensions/spectre-desktop-menu@spectre.os"
# Remove retired Spectre shell experiments from reused engineering roots.
# Polish7 keeps the isolated Panel, Insight and background-only Desktop Menu architecture.
sudo rm -rf "$TARGET/usr/share/gnome-shell/extensions/spectre-desktop-ux@spectre.os"

sudo install -m 0644 \
    "$BRANDING/schemas/org.spectre.desktop.gschema.xml" \
    "$TARGET/usr/share/glib-2.0/schemas/org.spectre.desktop.gschema.xml"

sudo install -m 0644 \
    "$BRANDING/pixmaps/spectre-logo.png" \
    "$TARGET/usr/share/pixmaps/spectre-logo.png"
sudo ln -sfn spectre-logo.png "$TARGET/usr/share/pixmaps/spectre-logo"

sudo install -m 0644 \
    "$BRANDING/pixmaps/spectre-avatar.png" \
    "$TARGET/usr/share/pixmaps/spectre-avatar.png"

# Preserve the branded alias used by existing Spectre account profiles.
sudo install -m 0644 "$BRANDING/pixmaps/spectre-avatar.png" \
    "$TARGET/var/lib/AccountsService/icons/spectre"
sudo install -m 0644 \
    "$BRANDING/backgrounds/spectre-login.png" \
    "$TARGET/usr/share/backgrounds/spectre/spectre-login.png"
sudo install -m 0644 \
    "$BRANDING/gdm/spectre-gdm-logo.png" \
    "$TARGET/usr/share/pixmaps/spectre-gdm-logo.png"

# Spectre animated boot splash.  The script plugin is intentionally lightweight
# so it remains usable under software graphics and early boot.
sudo rm -rf "$TARGET/usr/share/plymouth/themes/spectre"
sudo install -d "$TARGET/usr/share/plymouth/themes/spectre"
sudo cp -a "$BRANDING/plymouth/spectre/." \
    "$TARGET/usr/share/plymouth/themes/spectre/"

# Replace the default Debian user avatar for the pre-created Spectre account.
if [[ -d "$TARGET/home/$SPECTRE_USER" ]]; then
    sudo install -m 0644 "$BRANDING/pixmaps/spectre-avatar.png" \
        "$TARGET/var/lib/AccountsService/icons/$SPECTRE_USER"
    cat <<EOF2 | sudo tee "$TARGET/var/lib/AccountsService/users/$SPECTRE_USER" >/dev/null
[User]
Icon=/var/lib/AccountsService/icons/$SPECTRE_USER
SystemAccount=false
EOF2
fi

sudo install -m 0644 \
    "$BRANDING/spectre-ascii.txt" \
    "$TARGET/usr/share/spectre/spectre-ascii.txt"

sudo install -m 0755 \
    "$BRANDING/spectre-gnome-style.sh" \
    "$TARGET/usr/local/bin/spectre-gnome-style"

sudo install -m 0755 "$BRANDING/bin/spectre-welcome" \
    "$TARGET/usr/local/bin/spectre-welcome"
sudo install -m 0755 "$BRANDING/bin/spectre-center" \
    "$TARGET/usr/local/bin/spectre-center"
sudo install -m 0755 "$BRANDING/bin/spectre-diagnostics" \
    "$TARGET/usr/local/bin/spectre-diagnostics"
sudo install -m 0755 "$BRANDING/bin/spectre-update" \
    "$TARGET/usr/local/sbin/spectre-update"
sudo install -m 0755 "$BRANDING/bin/spectre-status" \
    "$TARGET/usr/local/bin/spectre-status"
sudo install -m 0755 "$BRANDING/bin/spectre-support-report" \
    "$TARGET/usr/local/bin/spectre-support-report"
sudo install -m 0755 "$BRANDING/bin/spectre-qualification" \
    "$TARGET/usr/local/bin/spectre-qualification"
sudo install -m 0755 "$BRANDING/bin/spectre-maintenance" \
    "$TARGET/usr/local/sbin/spectre-maintenance"
sudo install -m 0755 "$BRANDING/bin/spectre-installed-sanitize" \
    "$TARGET/usr/local/sbin/spectre-installed-sanitize"

sudo install -m 0755 "$BRANDING/bin/spectre-healthcheck" \
    "$TARGET/usr/local/sbin/spectre-healthcheck"
sudo install -m 0755 "$BRANDING/bin/spectre-shell-health" \
    "$TARGET/usr/local/bin/spectre-shell-health"
sudo install -m 0755 "$BRANDING/bin/spectre-taskbar-settings" \
    "$TARGET/usr/local/bin/spectre-taskbar-settings"
sudo install -m 0755 "$BRANDING/bin/spectre-desktop-refresh" \
    "$TARGET/usr/local/bin/spectre-desktop-refresh"
sudo install -m 0755 "$BRANDING/bin/spectre-patch-ding" \
    "$TARGET/usr/local/sbin/spectre-patch-ding"
sudo install -m 0755 "$BRANDING/bin/spectre-ding-reload" \
    "$TARGET/usr/local/bin/spectre-ding-reload"

# DING owns the full file-backed desktop when desktop icons are enabled. Patch
# the Debian Trixie-qualified 48.1.0-1 menu in-place rather than re-enabling a
# second Spectre background menu on top of it. The patcher is version/anchor
# guarded and intentionally fails the image build if the upstream layout moves.
sudo python3 "$BRANDING/bin/spectre-patch-ding" --root "$TARGET"
sudo install -m 0755 "$BRANDING/bin/spectre-appearance-sync" \
    "$TARGET/usr/local/bin/spectre-appearance-sync"
sudo install -m 0755 "$BRANDING/bin/spectre-desktop-apps" \
    "$TARGET/usr/local/bin/spectre-desktop-apps"
sudo install -m 0755 "$BRANDING/bin/spectre-desktop-state" \
    "$TARGET/usr/local/bin/spectre-desktop-state"
sudo install -m 0755 "$BRANDING/bin/spectre-run" "$TARGET/usr/local/bin/spectre-run"
sudo install -m 0755 "$BRANDING/bin/spectre-power-menu" "$TARGET/usr/local/bin/spectre-power-menu"
sudo install -m 0755 "$BRANDING/bin/spectre-files" "$TARGET/usr/local/bin/spectre-files"
sudo install -m 0755 "$BRANDING/bin/spectre-shortcut-defaults" "$TARGET/usr/local/bin/spectre-shortcut-defaults"
sudo install -m 0755 "$BRANDING/bin/spectre-shortcuts" "$TARGET/usr/local/bin/spectre-shortcuts"
sudo install -m 0755 "$BRANDING/bin/spectre-lock" "$TARGET/usr/local/bin/spectre-lock"
sudo install -m 0755 "$BRANDING/bin/spectre-clipboard" "$TARGET/usr/local/bin/spectre-clipboard"
sudo install -m 0755 "$BRANDING/bin/spectre-update-manager" "$TARGET/usr/local/bin/spectre-update-manager"
sudo install -m 0755 "$BRANDING/bin/spectre-hardware" "$TARGET/usr/local/bin/spectre-hardware"
sudo install -m 0755 "$BRANDING/bin/spectre-hardware-qualification" "$TARGET/usr/local/bin/spectre-hardware-qualification"
sudo install -m 0755 "$BRANDING/bin/spectre-suspend-qualification" "$TARGET/usr/local/bin/spectre-suspend-qualification"
sudo install -m 0755 "$BRANDING/bin/spectre-recovery" "$TARGET/usr/local/bin/spectre-recovery"
sudo install -m 0755 "$BRANDING/bin/spectre-installed-health" \
    "$TARGET/usr/local/bin/spectre-installed-health"
sudo install -m 0755 "$BRANDING/bin/spectre-installed-qualification" \
    "$TARGET/usr/local/bin/spectre-installed-qualification"
sudo install -m 0755 "$BRANDING/bin/spectre-boot-record" \
    "$TARGET/usr/local/sbin/spectre-boot-record"
sudo install -m 0644 "$BRANDING/systemd/spectre-healthcheck.service" \
    "$TARGET/etc/systemd/system/spectre-healthcheck.service"
sudo install -m 0644 "$BRANDING/systemd/spectre-boot-record.service" \
    "$TARGET/etc/systemd/system/spectre-boot-record.service"
sudo install -m 0644 "$BRANDING/systemd/spectre-maintenance.service" \
    "$TARGET/etc/systemd/system/spectre-maintenance.service"
sudo install -m 0644 "$BRANDING/systemd/spectre-maintenance.timer" \
    "$TARGET/etc/systemd/system/spectre-maintenance.timer"
sudo install -m 0644 "$BRANDING/systemd/spectre-installed-sanitize.service" \
    "$TARGET/etc/systemd/system/spectre-installed-sanitize.service"

# Daily-use resource policies.
sudo install -m 0644 "$BRANDING/system/journald-spectre.conf" \
    "$TARGET/etc/systemd/journald.conf.d/90-spectre.conf"
sudo install -m 0644 "$BRANDING/system/zram-generator.conf" \
    "$TARGET/etc/systemd/zram-generator.conf"
sudo install -m 0755 "$BRANDING/system/grub.d/42_spectre_recovery" \
    "$TARGET/etc/grub.d/42_spectre_recovery"
sudo install -d \
    "$TARGET/etc/systemd/system/multi-user.target.wants" \
    "$TARGET/etc/systemd/system/timers.target.wants"
sudo ln -sfn ../spectre-boot-record.service \
    "$TARGET/etc/systemd/system/multi-user.target.wants/spectre-boot-record.service"
sudo ln -sfn ../spectre-healthcheck.service \
    "$TARGET/etc/systemd/system/multi-user.target.wants/spectre-healthcheck.service"
sudo ln -sfn ../spectre-installed-sanitize.service \
    "$TARGET/etc/systemd/system/multi-user.target.wants/spectre-installed-sanitize.service"
sudo ln -sfn ../spectre-maintenance.timer \
    "$TARGET/etc/systemd/system/timers.target.wants/spectre-maintenance.timer"

# Enable upstream daily-use services when the package exists in this root.
for unit in fstrim.timer power-profiles-daemon.service bluetooth.service ufw.service apparmor.service switcheroo-control.service; do
    sudo chroot "$TARGET" systemctl enable "$unit" >/dev/null 2>&1 || true
done

# Conservative desktop firewall defaults: deny unsolicited inbound traffic,
# allow outbound traffic. This is written offline so image construction does not
# attempt to touch the host firewall.
if [[ -f "$TARGET/etc/default/ufw" ]]; then
    sudo sed -i \
      -e 's/^DEFAULT_INPUT_POLICY=.*/DEFAULT_INPUT_POLICY="DROP"/' \
      -e 's/^DEFAULT_OUTPUT_POLICY=.*/DEFAULT_OUTPUT_POLICY="ACCEPT"/' \
      -e 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="DROP"/' \
      -e 's/^IPV6=.*/IPV6=yes/' \
      "$TARGET/etc/default/ufw"
fi
if [[ -f "$TARGET/etc/ufw/ufw.conf" ]]; then
    sudo sed -i -e 's/^ENABLED=.*/ENABLED=yes/' -e 's/^LOGLEVEL=.*/LOGLEVEL=low/' \
      "$TARGET/etc/ufw/ufw.conf"
fi

sudo install -m 0644 "$BRANDING/applications/com.spectre.Welcome.desktop" \
    "$TARGET/usr/share/applications/com.spectre.Welcome.desktop"
sudo install -m 0644 "$BRANDING/applications/com.spectre.Center.desktop" \
    "$TARGET/usr/share/applications/com.spectre.Center.desktop"
sudo install -m 0644 "$BRANDING/applications/com.spectre.Diagnostics.desktop" \
    "$TARGET/usr/share/applications/com.spectre.Diagnostics.desktop"
sudo install -m 0644 "$BRANDING/applications/com.spectre.TaskbarSettings.desktop" \
    "$TARGET/usr/share/applications/com.spectre.TaskbarSettings.desktop"
sudo install -m 0644 "$BRANDING/applications/com.spectre.DesktopApps.desktop" \
    "$TARGET/usr/share/applications/com.spectre.DesktopApps.desktop"
sudo install -m 0644 "$BRANDING/applications/com.spectre.Shortcuts.desktop" \
    "$TARGET/usr/share/applications/com.spectre.Shortcuts.desktop"
sudo install -m 0644 "$BRANDING/applications/com.spectre.UpdateManager.desktop" \
    "$TARGET/usr/share/applications/com.spectre.UpdateManager.desktop"

sudo install -m 0644 \
    "$BRANDING/etc-skel/.config/autostart/spectre-gnome-style.desktop" \
    "$TARGET/etc/xdg/autostart/spectre-gnome-style.desktop"
sudo install -m 0644 \
    "$BRANDING/etc-skel/.config/autostart/spectre-welcome.desktop" \
    "$TARGET/etc/xdg/autostart/spectre-welcome.desktop"
sudo install -m 0644 \
    "$BRANDING/etc-skel/.config/autostart/spectre-appearance-sync.desktop" \
    "$TARGET/etc/xdg/autostart/spectre-appearance-sync.desktop"
sudo install -m 0644 \
    "$BRANDING/etc-skel/.config/autostart/spectre-clipboard.desktop" \
    "$TARGET/etc/xdg/autostart/spectre-clipboard.desktop"
sudo install -m 0644 \
    "$BRANDING/etc-skel/.config/autostart/spectre-desktop-state.desktop" \
    "$TARGET/etc/xdg/autostart/spectre-desktop-state.desktop"

# Defaults for new users.
sudo install -d \
    "$TARGET/etc/skel/.config/gtk-3.0" \
    "$TARGET/etc/skel/.config/gtk-4.0" \
    "$TARGET/etc/skel/.config/fastfetch"

sudo install -m 0644 "$BRANDING/etc-skel/.config/gtk-3.0/gtk.css" \
    "$TARGET/etc/skel/.config/gtk-3.0/gtk.css"
sudo install -m 0644 "$BRANDING/etc-skel/.config/gtk-3.0/settings.ini" \
    "$TARGET/etc/skel/.config/gtk-3.0/settings.ini"
sudo install -m 0644 "$BRANDING/etc-skel/.config/gtk-4.0/gtk.css" \
    "$TARGET/etc/skel/.config/gtk-4.0/gtk.css"
sudo install -m 0644 "$BRANDING/etc-skel/.config/fastfetch/config.jsonc" \
    "$TARGET/etc/skel/.config/fastfetch/config.jsonc"

# RC5.6.1: /etc/skel only affects users created later. The live `spectre`
# account already exists in the staged image, so seed the exact same adaptive
# GTK3 configuration into its home. The installer migrates this home to the
# installed username, keeping Live ISO and installed Spectre consistent.
if [[ -d "$TARGET/home/spectre" ]]; then
    spectre_uid="$(awk -F: '$1 == "spectre" {print $3; exit}' "$TARGET/etc/passwd")"
    spectre_gid="$(awk -F: '$1 == "spectre" {print $4; exit}' "$TARGET/etc/passwd")"
    if [[ -n "$spectre_uid" && -n "$spectre_gid" ]]; then
        sudo install -d -m 0755 "$TARGET/home/spectre/.config" "$TARGET/home/spectre/.config/gtk-3.0"
        sudo install -m 0644 "$BRANDING/etc-skel/.config/gtk-3.0/gtk.css" \
            "$TARGET/home/spectre/.config/gtk-3.0/gtk.css"
        sudo install -m 0644 "$BRANDING/etc-skel/.config/gtk-3.0/settings.ini" \
            "$TARGET/home/spectre/.config/gtk-3.0/settings.ini"
        sudo chown "$spectre_uid:$spectre_gid" \
            "$TARGET/home/spectre/.config" \
            "$TARGET/home/spectre/.config/gtk-3.0" \
            "$TARGET/home/spectre/.config/gtk-3.0/gtk.css" \
            "$TARGET/home/spectre/.config/gtk-3.0/settings.ini"
    fi
fi

if ! sudo grep -q 'Spectre interactive shell styling' "$TARGET/etc/skel/.bashrc" 2>/dev/null; then
    sudo sh -c "cat '$BRANDING/etc-skel/.bashrc.spectre' >> '$TARGET/etc/skel/.bashrc'"
fi

# System-wide GNOME defaults. Users can still change these settings.
cat <<'DCONF' | sudo tee "$TARGET/etc/dconf/db/local.d/00-spectre" >/dev/null
[org/gnome/desktop/interface]
color-scheme='prefer-dark'
gtk-theme='Adwaita-dark'
accent-color='blue'
icon-theme='Papirus-Dark'
cursor-theme='Adwaita'
font-name='Cantarell 11'
text-scaling-factor=1.0
monospace-font-name='Monospace 11'
enable-animations=true
clock-show-date=true

[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/spectre/collection/spectre-default-light.png'
picture-uri-dark='file:///usr/share/backgrounds/spectre/collection/spectre-default-dark.png'
picture-options='zoom'
primary-color='#020712'
secondary-color='#071b35'

[org/gnome/desktop/screensaver]
picture-uri='file:///usr/share/backgrounds/spectre/spectre-gnome.png'

# First-frame Shell defaults. The per-user RC5.6 migration applies the same
# deterministic list, but the image must not expose GNOME's native background
# menu while waiting for that autostart migration.
[org/gnome/shell]
enabled-extensions=['dash-to-dock@micxgx.gmail.com', 'apps-menu@gnome-shell-extensions.gcampax.github.com', 'places-menu@gnome-shell-extensions.gcampax.github.com', 'user-theme@gnome-shell-extensions.gcampax.github.com', 'spectre-panel@spectre.os', 'spectre-hud@spectre.os', 'spectre-desktop-menu@spectre.os', 'ding@rastersoft.com', 'ubuntu-appindicators@ubuntu.com']

[org/gnome/mutter]
dynamic-workspaces=false

[org/gnome/desktop/wm/preferences]
num-workspaces=4
workspace-names=['1', '2', '3', '4']
button-layout=':minimize,maximize,close'

[org/gnome/desktop/peripherals/touchpad]
tap-to-click=true
natural-scroll=false

[org/gnome/desktop/privacy]
remember-recent-files=true
remove-old-trash-files=true
remove-old-temp-files=true
old-files-age=30

[org/spectre/desktop]
wallpaper-mode='spectre-auto'
appearance-profile='dark'
windows-shortcuts-initialized=false
show-hud=true
show-system-card=true
show-network-card=true
hud-compact=false
app-grid-initialized=false

[org/gnome/shell/extensions/ding]
show-home=false
show-trash=false
show-volumes=false
show-network-volumes=false

[org/gnome/shell/extensions/dash-to-dock]
dock-position='LEFT'
extend-height=false
dock-fixed=false
intellihide=true
intellihide-mode='MAXIMIZED_WINDOWS'
autohide=true
autohide-in-fullscreen=true
require-pressure-to-show=false
pressure-threshold=35.0
animation-time=0.16
show-delay=0.00
hide-delay=0.12
dash-max-icon-size=42
icon-size-fixed=true
transparency-mode='DYNAMIC'
customize-alphas=true
min-alpha=0.16
max-alpha=0.58
background-opacity=0.36
custom-background-color=true
background-color='#020b18'
custom-theme-shrink=true
show-trash=false
show-mounts=false
show-show-apps-button=true
show-apps-at-top=false
show-favorites=true
show-running=true
isolate-workspaces=false
running-indicator-style='DOTS'
click-action='focus-minimize-or-previews'
show-windows-preview=true
DCONF

# SPECTRE_REALOS_RUNTIME_V1
sudo install -d -m 0755 "$TARGET/usr/local/share/spectre"
sudo install -m 0644 "$BRANDING/share/spectre/ding-menu.css" "$TARGET/usr/local/share/spectre/ding-menu.css"
sudo install -m 0755 "$BRANDING/bin/spectre-real-os-audit" "$TARGET/usr/local/bin/spectre-real-os-audit"

# SPECTRE_FIRSTBOOT_UI_V1
# Permanent first-frame GTK3/DING policy.  The local dconf database must be
# consumed and compiled before GDM starts the first installed user session.
sudo install -d -m 0755 "$TARGET/etc/dconf/profile" "$TARGET/etc/gtk-3.0"
cat <<'SPECTRE_DCONF_PROFILE' | sudo tee "$TARGET/etc/dconf/profile/user" >/dev/null
user-db:user
system-db:local
SPECTRE_DCONF_PROFILE

# GTK3 startup fallback. GNOME/XSettings and user GSettings still own later
# Light/Dark changes; this prevents DING from starting with GTK's light fallback.
cat <<'SPECTRE_GTK3_SETTINGS' | sudo tee "$TARGET/etc/gtk-3.0/settings.ini" >/dev/null
[Settings]
gtk-theme-name=Adwaita-dark
gtk-application-prefer-dark-theme=1
SPECTRE_GTK3_SETTINGS

if [[ -x "$TARGET/usr/bin/dconf" ]]; then
    sudo chroot "$TARGET" /usr/bin/dconf update
else
    echo "[Spectre] ERROR: dconf missing from target; first-boot defaults cannot be compiled." >&2
    exit 1
fi
# END SPECTRE_FIRSTBOOT_UI_V1


if [[ ! -f "$TARGET/etc/dconf/profile/user" ]]; then
    cat <<'PROFILE' | sudo tee "$TARGET/etc/dconf/profile/user" >/dev/null
user-db:user
system-db:local
PROFILE
elif ! sudo grep -q '^system-db:local$' "$TARGET/etc/dconf/profile/user"; then
    echo 'system-db:local' | sudo tee -a "$TARGET/etc/dconf/profile/user" >/dev/null
fi

# Spectre greeter security policy.
if [[ -f "$BRANDING/gdm/10-spectre-security" ]]; then
    sudo install -m 0644 "$BRANDING/gdm/10-spectre-security" \
        "$TARGET/etc/dconf/db/gdm.d/10-spectre-security"
fi

# GDM branding / login message. The greeter remains GNOME-native.
cat <<'GDM' | sudo tee "$TARGET/etc/dconf/db/gdm.d/00-spectre" >/dev/null
[org/gnome/login-screen]
logo='/usr/share/pixmaps/spectre-logo.png'
banner-message-enable=true
banner-message-text='SPECTRE OS'
disable-user-list=false

[org/gnome/desktop/interface]
color-scheme='prefer-dark'
accent-color='blue'

[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/spectre/collection/spectre-default-dark.png'
picture-uri-dark='file:///usr/share/backgrounds/spectre/collection/spectre-default-dark.png'
picture-options='zoom'
primary-color='#020712'
secondary-color='#071b35'
GDM

if [[ ! -f "$TARGET/etc/dconf/profile/gdm" ]]; then
    cat <<'PROFILE' | sudo tee "$TARGET/etc/dconf/profile/gdm" >/dev/null
user-db:user
system-db:gdm
file-db:/usr/share/gdm/greeter-dconf-defaults
PROFILE
elif ! sudo grep -q '^system-db:gdm$' "$TARGET/etc/dconf/profile/gdm"; then
    echo 'system-db:gdm' | sudo tee -a "$TARGET/etc/dconf/profile/gdm" >/dev/null
fi

# Install styling into an already-created Spectre user's home too.
USER_HOME="$TARGET/home/$SPECTRE_USER"
if [[ -d "$USER_HOME" ]]; then
    sudo install -d \
        "$USER_HOME/.config/gtk-3.0" \
        "$USER_HOME/.config/gtk-4.0" \
        "$USER_HOME/.config/fastfetch"
    sudo install -m 0644 "$BRANDING/etc-skel/.config/gtk-3.0/gtk.css" "$USER_HOME/.config/gtk-3.0/gtk.css"
    sudo install -m 0644 "$BRANDING/etc-skel/.config/gtk-3.0/settings.ini" "$USER_HOME/.config/gtk-3.0/settings.ini"
    sudo install -m 0644 "$BRANDING/etc-skel/.config/gtk-4.0/gtk.css" "$USER_HOME/.config/gtk-4.0/gtk.css"
    sudo install -m 0644 "$BRANDING/etc-skel/.config/fastfetch/config.jsonc" "$USER_HOME/.config/fastfetch/config.jsonc"
    if ! sudo grep -q 'Spectre interactive shell styling' "$USER_HOME/.bashrc" 2>/dev/null; then
        sudo sh -c "cat '$BRANDING/etc-skel/.bashrc.spectre' >> '$USER_HOME/.bashrc'"
    fi
    uid="$(sudo chroot "$TARGET" id -u "$SPECTRE_USER")"
    gid="$(sudo chroot "$TARGET" id -g "$SPECTRE_USER")"
    sudo chown -R "$uid:$gid" "$USER_HOME/.config" "$USER_HOME/.bashrc"
fi

# Compile dconf databases if dconf exists in the new rootfs.
if [[ -x "$TARGET/usr/bin/dconf" ]]; then
    sudo chroot "$TARGET" dconf update || true
fi

# Refresh GLib schemas after extension/theme package changes.
if [[ -x "$TARGET/usr/bin/glib-compile-schemas" && -d "$TARGET/usr/share/glib-2.0/schemas" ]]; then
    sudo chroot "$TARGET" glib-compile-schemas /usr/share/glib-2.0/schemas || true
fi

# Make Spectre the default Plymouth theme.  install-kernel.sh will create the
# initramfs later on a clean build; on an already-built rootfs, refresh existing
# initramfs images immediately so Debian branding does not reappear.
if [[ -x "$TARGET/usr/sbin/plymouth-set-default-theme" ]]; then
    sudo chroot "$TARGET" plymouth-set-default-theme spectre || true
    if [[ "${SPECTRE_SKIP_INITRAMFS_REFRESH:-0}" == "1" ]]; then
        echo "[Spectre] Deferring initramfs refresh to the image builder."
    elif compgen -G "$TARGET/boot/initrd.img-*" >/dev/null && [[ -x "$TARGET/usr/sbin/update-initramfs" ]]; then
        sudo chroot "$TARGET" update-initramfs -u -k all || true
    fi
fi

# Repair only the qualified alsa-utils udev label defect.
# Newer vendor rules are left untouched.
ALSA_FIX="$ROOT/profiles/gnome/branding/build/fix-alsa-restore-rule.sh"
if [[ -x "$ALSA_FIX" ]]; then
    "$ALSA_FIX" "$TARGET"
fi

if [[ -x "$ROOT/profiles/gnome/finalize-spectre-identity.sh" ]]; then
    "$ROOT/profiles/gnome/finalize-spectre-identity.sh" "$TARGET"
fi


# SPECTRE_GDM_LOCKSCREEN_SOURCE_V1 BEGIN
# Compile the Spectre login artwork directly into GNOME Shell's greeter
# resource while building the target root. This is a source/build-time change,
# not a first-login user patch.
_spectre_gnome_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
"$_spectre_gnome_dir/patch-gdm-theme.sh" "$TARGET"
# SPECTRE_GDM_LOCKSCREEN_SOURCE_V1 END

echo "[ok] Spectre GNOME branding installed."
echo "     The first GNOME login applies dock, extensions, terminal colors and layout."

# BEGIN SPECTRE-1.0-RESTORE-INSTALLER-LIGHT-WALLPAPERS
_SPECTRE_I="$ROOT/profiles/gnome/installer"
_SPECTRE_B="$ROOT/profiles/gnome/branding"

for _f in   "$_SPECTRE_I/spectre-live-installer-setup"   "$_SPECTRE_I/spectre-installer-launcher"   "$_SPECTRE_I/spectre-installer"   "$_SPECTRE_I/spectre-installer-backend"   "$_SPECTRE_I/com.spectre.Installer.desktop"   "$_SPECTRE_I/spectre-live-installer.desktop"   "$_SPECTRE_I/assets/spectre-installer.png"   "$_SPECTRE_B/themes/Spectre-Day/gnome-shell/gnome-shell.css"   "$_SPECTRE_B/backgrounds/spectre.xml"   "$_SPECTRE_B/backgrounds/collection/spectre-default-dark.png"   "$_SPECTRE_B/backgrounds/collection/spectre-default-light.png"   "$_SPECTRE_B/bin/spectre-appearance-sync"
do
  [[ -f "$_f" ]] || { echo "[FAIL] missing release asset: $_f" >&2; exit 1; }
done

sudo install -Dm755 "$_SPECTRE_I/spectre-live-installer-setup" "$TARGET/usr/local/bin/spectre-live-installer-setup"
sudo install -Dm755 "$_SPECTRE_I/spectre-installer-launcher" "$TARGET/usr/local/bin/spectre-installer-launcher"
sudo install -Dm755 "$_SPECTRE_I/spectre-installer" "$TARGET/usr/local/sbin/spectre-installer"
sudo install -Dm755 "$_SPECTRE_I/spectre-installer-backend" "$TARGET/usr/local/sbin/spectre-installer-backend"
sudo install -Dm644 "$_SPECTRE_I/com.spectre.Installer.desktop" "$TARGET/usr/share/applications/com.spectre.Installer.desktop"
sudo install -Dm644 "$_SPECTRE_I/spectre-live-installer.desktop" "$TARGET/etc/xdg/autostart/spectre-live-installer.desktop"
sudo install -Dm644 "$_SPECTRE_I/assets/spectre-installer.png" "$TARGET/usr/share/pixmaps/spectre-installer.png"

for _size in 48 64 128 256 512; do
  _icon="$_SPECTRE_I/icons/${_size}x${_size}/apps/spectre-installer.png"
  [[ -f "$_icon" ]] && sudo install -Dm644 "$_icon" "$TARGET/usr/share/icons/hicolor/${_size}x${_size}/apps/spectre-installer.png"
done

sudo install -d -m 0755 "$TARGET/etc/polkit-1/rules.d"
sudo tee "$TARGET/etc/polkit-1/rules.d/49-spectre-installer.rules" >/dev/null <<'POLKIT'
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.policykit.exec" &&
        action.lookup("program") == "/usr/local/sbin/spectre-installer-backend" &&
        subject.user == "spectre" &&
        subject.local && subject.active) {
        return polkit.Result.YES;
    }
});
POLKIT
sudo chmod 0644 "$TARGET/etc/polkit-1/rules.d/49-spectre-installer.rules"

sudo install -Dm644 "$_SPECTRE_B/themes/Spectre-Day/gnome-shell/gnome-shell.css" "$TARGET/usr/share/themes/Spectre-Day/gnome-shell/gnome-shell.css"
sudo install -Dm755 "$_SPECTRE_B/bin/spectre-appearance-sync" "$TARGET/usr/local/bin/spectre-appearance-sync"

_APPEARANCE_AUTOSTART="$(find "$_SPECTRE_B" -type f -name 'spectre-appearance-sync.desktop' -print -quit 2>/dev/null || true)"
if [[ -n "$_APPEARANCE_AUTOSTART" ]]; then
  sudo install -Dm644 "$_APPEARANCE_AUTOSTART" "$TARGET/etc/xdg/autostart/spectre-appearance-sync.desktop"
else
  sudo install -d -m 0755 "$TARGET/etc/xdg/autostart"
  sudo tee "$TARGET/etc/xdg/autostart/spectre-appearance-sync.desktop" >/dev/null <<'AUTO'
[Desktop Entry]
Type=Application
Name=Spectre Appearance Sync
Exec=/usr/local/bin/spectre-appearance-sync
NoDisplay=true
X-GNOME-Autostart-enabled=true
OnlyShowIn=GNOME;
AUTO
  sudo chmod 0644 "$TARGET/etc/xdg/autostart/spectre-appearance-sync.desktop"
fi

sudo install -d -m 0755 "$TARGET/usr/share/backgrounds/spectre/collection" "$TARGET/usr/share/gnome-background-properties"
sudo cp -a "$_SPECTRE_B/backgrounds/collection/." "$TARGET/usr/share/backgrounds/spectre/collection/"
sudo find "$TARGET/usr/share/backgrounds/spectre/collection" -type f -exec chmod 0644 {} +
sudo install -Dm644 "$_SPECTRE_B/backgrounds/spectre.xml" "$TARGET/usr/share/gnome-background-properties/spectre.xml"

sudo chroot "$TARGET" /bin/sh -c 'command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications || true'
sudo chroot "$TARGET" /bin/sh -c 'command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -f -t /usr/share/icons/hicolor >/dev/null 2>&1 || true'

echo "[ok] Spectre installer + light mode + wallpapers staged."
# END SPECTRE-1.0-RESTORE-INSTALLER-LIGHT-WALLPAPERS

# BEGIN SPECTRE-1.0-LIVE-INSTALLER-VISIBILITY-v1.1
_SI="$ROOT/profiles/gnome/installer"
_VISIBLE="$_SI/com.spectre.Installer.desktop"

[[ -f "$_VISIBLE" ]] || { echo "[FAIL] visible installer desktop entry missing: $_VISIBLE" >&2; exit 1; }
[[ -x "$_SI/runtime/spectre-live-installer-shortcut-setup" ]] || { echo "[FAIL] installer shortcut helper missing" >&2; exit 1; }
[[ -f "$_SI/runtime/spectre-live-installer-shortcut.desktop" ]] || { echo "[FAIL] installer shortcut autostart missing" >&2; exit 1; }

# IMPORTANT: /usr/share/applications must get the dedicated VISIBLE entry.
# Do not copy the hidden autostart entry into the application grid.
sudo install -Dm644 "$_VISIBLE" \
  "$TARGET/usr/share/applications/com.spectre.Installer.desktop"

sudo install -Dm755 "$_SI/runtime/spectre-live-installer-shortcut-setup" \
  "$TARGET/usr/local/bin/spectre-live-installer-shortcut-setup"

sudo install -Dm644 "$_SI/runtime/spectre-live-installer-shortcut.desktop" \
  "$TARGET/etc/xdg/autostart/spectre-live-installer-shortcut.desktop"

# Seed a shortcut for newly-created live homes.
sudo install -d -m 0755 "$TARGET/etc/skel/Desktop"
sudo install -m 0755 "$_VISIBLE" \
  "$TARGET/etc/skel/Desktop/Install Spectre OS.desktop"

# The engineering UEFI image already contains the live user's home. Seed it too.
if [[ -d "$TARGET/home/spectre" ]]; then
  sudo install -d -m 0755 "$TARGET/home/spectre/Desktop"
  sudo install -m 0755 "$_VISIBLE" \
    "$TARGET/home/spectre/Desktop/Install Spectre OS.desktop"
  if id spectre >/dev/null 2>&1; then
    :
  fi
  # Resolve target UID/GID from the staged passwd rather than the host.
  _uid="$(awk -F: '$1=="spectre"{print $3; exit}' "$TARGET/etc/passwd" 2>/dev/null || true)"
  _gid="$(awk -F: '$1=="spectre"{print $4; exit}' "$TARGET/etc/passwd" 2>/dev/null || true)"
  if [[ -n "$_uid" && -n "$_gid" ]]; then
    sudo chown "$_uid:$_gid" "$TARGET/home/spectre/Desktop" \
      "$TARGET/home/spectre/Desktop/Install Spectre OS.desktop"
  fi
fi

sudo chroot "$TARGET" /bin/sh -c \
  'command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications || true'

echo "[ok] Visible live installer launcher + desktop shortcut staged."
# END SPECTRE-1.0-LIVE-INSTALLER-VISIBILITY-v1.1


# SPECTRE_TOOLHUB_V1 BEGIN
# First-party Spectre system utility. Kali content itself remains on-demand in
# an isolated rootless container and is never added to host APT sources.
if [[ -x "$ROOT/profiles/gnome/toolhub/install-toolhub.sh" ]]; then
    SPECTRE_GNOME_ROOTFS="$TARGET" "$ROOT/profiles/gnome/toolhub/install-toolhub.sh"
fi
# SPECTRE_TOOLHUB_V1 END
