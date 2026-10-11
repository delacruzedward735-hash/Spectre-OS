#!/usr/bin/env bash
# Apply the Spectre GNOME desktop layout for the current user.
set -u

MARKER="$HOME/.config/spectre/theme-0.9-rc56-applied"
RC55_MARKER="$HOME/.config/spectre/theme-0.9-rc55-applied"
LEGACY_MARKER="$HOME/.config/spectre/theme-0.9-polish6-applied"
FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

if [[ "$FORCE" -eq 0 && -f "$MARKER" ]]; then
    exit 0
fi

mkdir -p "$HOME/.config/spectre"

# RC5.6 desktop/runtime migration.
/usr/local/bin/spectre-desktop-state --migrate >/dev/null 2>&1 || true

has_schema() {
    gsettings list-schemas 2>/dev/null | grep -Fxq "$1"
}

has_key() {
    has_schema "$1" || return 1
    gsettings list-keys "$1" 2>/dev/null | grep -Fxq "$2"
}

gset() {
    local schema="$1" key="$2" value="$3"
    if has_key "$schema" "$key"; then
        gsettings set "$schema" "$key" "$value" >/dev/null 2>&1 || true
    fi
}

greset_recursive() {
    local schema="$1"
    if has_schema "$schema"; then
        gsettings reset-recursively "$schema" >/dev/null 2>&1 || true
    fi
}

enable_extension() {
    local uuid="$1"
    if [[ -d "/usr/share/gnome-shell/extensions/$uuid" || -d "$HOME/.local/share/gnome-shell/extensions/$uuid" ]]; then
        gnome-extensions enable "$uuid" >/dev/null 2>&1 || true
    fi
}

disable_extension() {
    gnome-extensions disable "$1" >/dev/null 2>&1 || true
}

# Existing Spectre users already have their desktop choices. Upgrade only the
# new appearance synchronizer and shortcut profile; never reset their wallpaper,
# favorites, taskbar or other established preferences.
if [[ "$FORCE" -eq 0 && ( -f "$RC55_MARKER" || -f "$LEGACY_MARKER" ) ]]; then
    /usr/local/bin/spectre-appearance-sync --once >/dev/null 2>&1 || true
    /usr/local/bin/spectre-shortcut-defaults --once >/dev/null 2>&1 || true
    touch "$MARKER"
    exit 0
fi

# Core GNOME look.
gset org.gnome.desktop.interface color-scheme "'prefer-dark'"
gset org.gnome.desktop.interface gtk-theme "'Adwaita-dark'"
gset org.gnome.desktop.interface accent-color "'blue'"
gset org.gnome.desktop.interface icon-theme "'Papirus-Dark'"
gset org.gnome.desktop.interface cursor-theme "'Adwaita'"
gset org.gnome.desktop.interface font-name "'Cantarell 11'"
gset org.gnome.desktop.interface text-scaling-factor 1.0
gset org.gnome.desktop.interface document-font-name "'Cantarell 11'"
gset org.gnome.desktop.interface monospace-font-name "'Monospace 11'"
gset org.gnome.desktop.interface enable-animations true

gset org.gnome.desktop.background picture-uri "'file:///usr/share/backgrounds/spectre/collection/spectre-default-light.png'"
gset org.gnome.desktop.background picture-uri-dark "'file:///usr/share/backgrounds/spectre/collection/spectre-default-dark.png'"
gset org.gnome.desktop.background picture-options "'zoom'"
gset org.gnome.desktop.background primary-color "'#020712'"
gset org.gnome.desktop.background secondary-color "'#071b35'"
gset org.gnome.desktop.screensaver picture-uri "'file:///usr/share/backgrounds/spectre/collection/spectre-default-dark.png'"

# Four fixed workspaces, matching the numbered workspace concept.
gset org.gnome.mutter dynamic-workspaces false
gset org.gnome.desktop.wm.preferences num-workspaces 4
gset org.gnome.desktop.wm.preferences workspace-names "['1', '2', '3', '4']"
gset org.gnome.desktop.wm.preferences button-layout "':minimize,maximize,close'"
gset org.gnome.desktop.wm.preferences focus-mode "'click'"

gset org.gnome.desktop.interface clock-show-date true
gset org.gnome.desktop.interface clock-show-weekday false
gset org.gnome.desktop.interface clock-show-seconds false

# Useful default favorites for the left dock.
gset org.gnome.shell favorite-apps "['org.gnome.Nautilus.desktop', 'org.gnome.Terminal.desktop', 'firefox-esr.desktop', 'com.spectre.Center.desktop', 'org.gnome.Settings.desktop']"

# Productivity defaults that keep the desktop close to the Spectre concept.
gset org.gnome.desktop.peripherals.touchpad tap-to-click true
gset org.gnome.desktop.peripherals.touchpad natural-scroll false
gset org.gnome.desktop.wm.keybindings close "['<Alt>F4']"
# Spectre Shell owns Super+Arrow directional half/quarter tiling. Keep the
# native GNOME/Mutter bindings collision-free and retain maximize/restore on
# Shift+Super+Up/Down.
gset org.gnome.desktop.wm.keybindings maximize "['<Shift><Super>Up']"
gset org.gnome.desktop.wm.keybindings unmaximize "['<Shift><Super>Down']"
gset org.gnome.mutter.keybindings toggle-tiled-left "[]"
gset org.gnome.mutter.keybindings toggle-tiled-right "[]"
gset org.gnome.desktop.wm.keybindings switch-to-workspace-left "['<Control><Super>Left']"
gset org.gnome.desktop.wm.keybindings switch-to-workspace-right "['<Control><Super>Right']"

# Keep the extension surface deterministic. Captured engineering images can
# carry obsolete system extensions in dconf defaults, so replace the enabled
# list instead of incrementally enabling more extensions on top of stale state.
gset org.gnome.shell enabled-extensions "['dash-to-dock@micxgx.gmail.com', 'apps-menu@gnome-shell-extensions.gcampax.github.com', 'places-menu@gnome-shell-extensions.gcampax.github.com', 'user-theme@gnome-shell-extensions.gcampax.github.com', 'spectre-panel@spectre.os', 'spectre-hud@spectre.os', 'spectre-desktop-menu@spectre.os', 'ding@rastersoft.com', 'ubuntu-appindicators@ubuntu.com']"

for retired_extension in \
    spectre-desktop-ux@spectre.os \
    status-icons@gnome-shell-extensions.gcampax.github.com \
    workspace-indicator@gnome-shell-extensions.gcampax.github.com \
    Hide_Activities@shay.shayel.org \
    tiling-assistant@leleat-on-github \
    blur-my-shell@aunetx; do
    disable_extension "$retired_extension"
done

# DING remains the single file-backed desktop provider.  The Spectre Shell
# desktop-menu extension is enabled only as a background fallback for the
# uncovered GNOME Shell regions that can appear while DING resizes/reconfigures
# its per-monitor desktop windows.  It deliberately refuses normal windows,
# panels and the dock, so it never competes with DING where DING is active.
gset org.gnome.shell.extensions.ding show-home false
gset org.gnome.shell.extensions.ding show-trash false
gset org.gnome.shell.extensions.ding show-volumes false
gset org.gnome.shell.extensions.ding show-network-volumes false
enable_extension 'ding@rastersoft.com'
enable_extension 'spectre-desktop-menu@spectre.os'

# Retire the old Conky fallback at runtime too. A reused engineering home can
# contain a stale autostart entry even after the package/config was removed from
# the image. Spectre Insight is the only supported desktop monitor.
pkill -x conky >/dev/null 2>&1 || true
rm -f "$HOME/.config/autostart/"*conky*.desktop 2>/dev/null || true
rm -rf "$HOME/.config/conky" 2>/dev/null || true

# Synchronize GTK3 with GNOME's native Dark Style preference. GTK4/Libadwaita
# follows color-scheme directly; this companion keeps legacy apps consistent.
/usr/local/bin/spectre-appearance-sync --once >/dev/null 2>&1 || true
/usr/local/bin/spectre-shortcut-defaults --once >/dev/null 2>&1 || true

# Spectre native desktop HUD.
gset org.spectre.desktop show-hud true
gset org.spectre.desktop show-system-card true
gset org.spectre.desktop show-network-card true
gset org.spectre.desktop hud-compact false
gset org.spectre.desktop app-grid-initialized false
gset org.spectre.desktop wallpaper-mode "'spectre-auto'"

# User shell theme.
gset org.gnome.shell.extensions.user-theme name "'Spectre-Night'"

# Spectre Taskbar / Dash-to-Dock. Polish8 keeps the smooth Polish7 motion and
# glass styling, while enabling Dash-to-Dock's own hover/autohide path together
# with intellihide. This is the supported combination that lets the taskbar hide
# for maximized windows yet reliably reveal when the pointer reaches its edge.
# All keys are feature-detected by gset(), so newer/older Dash-to-Dock builds
# can safely ignore settings they do not provide.
gset org.gnome.shell.extensions.dash-to-dock dock-position "'LEFT'"
gset org.gnome.shell.extensions.dash-to-dock extend-height false
gset org.gnome.shell.extensions.dash-to-dock dock-fixed false
gset org.gnome.shell.extensions.dash-to-dock intellihide true
gset org.gnome.shell.extensions.dash-to-dock intellihide-mode "'MAXIMIZED_WINDOWS'"
gset org.gnome.shell.extensions.dash-to-dock autohide true
gset org.gnome.shell.extensions.dash-to-dock autohide-in-fullscreen true
gset org.gnome.shell.extensions.dash-to-dock require-pressure-to-show false
gset org.gnome.shell.extensions.dash-to-dock pressure-threshold 35.0
gset org.gnome.shell.extensions.dash-to-dock animation-time 0.16
gset org.gnome.shell.extensions.dash-to-dock show-delay 0.00
gset org.gnome.shell.extensions.dash-to-dock hide-delay 0.12
gset org.gnome.shell.extensions.dash-to-dock dash-max-icon-size 42
gset org.gnome.shell.extensions.dash-to-dock icon-size-fixed true
gset org.gnome.shell.extensions.dash-to-dock transparency-mode "'DYNAMIC'"
gset org.gnome.shell.extensions.dash-to-dock customize-alphas true
gset org.gnome.shell.extensions.dash-to-dock min-alpha 0.16
gset org.gnome.shell.extensions.dash-to-dock max-alpha 0.58
gset org.gnome.shell.extensions.dash-to-dock background-opacity 0.36
gset org.gnome.shell.extensions.dash-to-dock custom-background-color true
gset org.gnome.shell.extensions.dash-to-dock background-color "'#020b18'"
gset org.gnome.shell.extensions.dash-to-dock custom-theme-shrink true
gset org.gnome.shell.extensions.dash-to-dock show-trash false
gset org.gnome.shell.extensions.dash-to-dock show-mounts false
gset org.gnome.shell.extensions.dash-to-dock show-show-apps-button true
gset org.gnome.shell.extensions.dash-to-dock show-apps-at-top false
gset org.gnome.shell.extensions.dash-to-dock show-favorites true
gset org.gnome.shell.extensions.dash-to-dock show-running true
gset org.gnome.shell.extensions.dash-to-dock isolate-workspaces false
gset org.gnome.shell.extensions.dash-to-dock running-indicator-style "'DOTS'"
gset org.gnome.shell.extensions.dash-to-dock click-action "'focus-minimize-or-previews'"
gset org.gnome.shell.extensions.dash-to-dock show-windows-preview true

# Clear stale folder metadata once. Spectre Panel also resets GNOME Shell's
# app-picker layout to its Shell-managed default after AppSystem has discovered
# launchers, then leaves later user rearrangements untouched.
greset_recursive org.gnome.desktop.app-folders

# Terminal palette: near-black navy with electric-blue/cyan accents.
if has_schema org.gnome.Terminal.ProfilesList; then
    profile_id="$(gsettings get org.gnome.Terminal.ProfilesList default 2>/dev/null | tr -d "'" || true)"
    if [[ -n "$profile_id" ]]; then
        profile="org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:${profile_id}/"
        profile_has_key() {
            gsettings list-keys "$profile" 2>/dev/null | grep -Fxq "$1"
        }
        profile_set() {
            local key="$1" value="$2"
            if profile_has_key "$key"; then
                gsettings set "$profile" "$key" "$value" >/dev/null 2>&1 || true
            fi
        }
        profile_set use-theme-colors false
        profile_set foreground-color "'rgb(220,235,255)'"
        profile_set background-color "'rgb(2,8,18)'"
        profile_set bold-color-same-as-fg true
        profile_set cursor-colors-set true
        profile_set cursor-background-color "'rgb(34,185,255)'"
        profile_set cursor-foreground-color "'rgb(2,8,18)'"
        profile_set palette "['rgb(5,10,18)', 'rgb(255,79,108)', 'rgb(66,210,127)', 'rgb(255,201,93)', 'rgb(20,126,232)', 'rgb(160,89,255)', 'rgb(34,185,255)', 'rgb(225,238,255)', 'rgb(61,75,96)', 'rgb(255,107,132)', 'rgb(89,229,151)', 'rgb(255,214,119)', 'rgb(80,161,255)', 'rgb(184,127,255)', 'rgb(99,211,255)', 'rgb(255,255,255)']"
    fi
fi

# Nautilus / Files defaults.
gset org.gnome.nautilus.preferences default-folder-viewer "'icon-view'"
gset org.gnome.nautilus.icon-view default-zoom-level "'medium'"
# Keep GNOME Files as the directory handler on a fresh Spectre profile. This
# avoids stale MIME associations making both dock clicks and Super+E appear
# dead. The style script is marker-gated, so later user choices are preserved.
if command -v xdg-mime >/dev/null 2>&1; then
    xdg-mime default org.gnome.Nautilus.desktop inode/directory >/dev/null 2>&1 || true
    xdg-mime default org.gnome.Nautilus.desktop application/x-gnome-saved-search >/dev/null 2>&1 || true
fi


# Keep the theme marker last so a partially applied configuration retries.
touch "$MARKER"
exit 0
