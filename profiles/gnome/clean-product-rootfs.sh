#!/usr/bin/env bash
# Remove stale/uncontrolled personal-product integrations before RC6 reinjects the explicit app profile.
set -euo pipefail

TARGET="${1:-}"
[[ -n "$TARGET" ]] || { echo "usage: $0 /path/to/rootfs" >&2; exit 2; }
TARGET="$(readlink -f "$TARGET")"
[[ "$TARGET" != "/" && -d "$TARGET/etc" && -d "$TARGET/usr" ]] || {
    echo "Refusing unsafe or incomplete rootfs target: $TARGET" >&2
    exit 2
}

echo "[Spectre] Enforcing the core-OS product boundary in: $TARGET"

# Remove any stale artifact belonging to a controlled personal app. The current
# version is reinstalled later from profiles/gnome/personal-apps.
# find does not follow symlinks, and every result is constrained below TARGET.
while IFS= read -r -d '' artifact; do
    [[ "$artifact" == "$TARGET"/* ]] || {
        echo "Refusing out-of-root artifact: $artifact" >&2
        exit 3
    }
    printf '[REMOVE] %s\n' "${artifact#$TARGET}"
    sudo rm -rf -- "$artifact"
done < <(sudo find "$TARGET" -xdev \( -iname '*swiftshare*' -o -iname '*appsweep*' \) -print0)

# A launcher or service can use an unrelated filename. Remove matching
# integration files only from locations where an entire file represents one
# application, autostart entry, service, policy or menu item.
integration_dirs=(
    etc/xdg/autostart
    etc/systemd/system
    etc/polkit-1/rules.d
    usr/lib/systemd/system
    usr/share/applications
    usr/local/share/applications
)
for relative in "${integration_dirs[@]}"; do
    directory="$TARGET/$relative"
    [[ -d "$directory" ]] || continue
    while IFS= read -r -d '' integration; do
        printf '[REMOVE] %s\n' "${integration#$TARGET}"
        sudo rm -f -- "$integration"
    done < <(sudo grep -RIlZiE 'swift[[:space:]_.-]*share|com[.]swiftshare|appsweep' "$directory" 2>/dev/null || true)
done

# A captured development account can carry stale favorites and autostart state
# in its binary dconf database. Recreate user settings from Spectre's system
# defaults on first login instead of publishing that mutable developer state.
if [[ -d "$TARGET/home/spectre" ]]; then
    sudo rm -f "$TARGET/home/spectre/.config/dconf/user"
    sudo rm -rf "$TARGET/home/spectre/.cache/gnome-shell"
    sudo rm -rf "$TARGET/home/spectre/.config/conky"
    sudo rm -f "$TARGET/home/spectre/.config/autostart/"*conky*.desktop 2>/dev/null || true
    sudo rm -f "$TARGET/home/spectre/.config/spectre/theme-"*-applied
fi

# If a reused engineering image installed deferred products or the retired
# Conky monitor as Debian packages, remove their package records and payload
# before the SquashFS is captured. Spectre Insight is the sole monitor.
if [[ -x "$TARGET/usr/bin/dpkg-query" && -x "$TARGET/usr/bin/apt-get" ]]; then
    mapfile -t packages < <(
        sudo chroot "$TARGET" dpkg-query -W -f='${binary:Package}\n' 2>/dev/null |
            grep -Ei 'swiftshare|^conky([:-]|$)|appsweep' || true
    )
    if ((${#packages[@]})); then
        printf '[REMOVE] packages: %s\n' "${packages[*]}"
        sudo chroot "$TARGET" apt-get purge -y "${packages[@]}"
    fi
fi

echo "[ok] Stale personal-product cleanup complete; controlled RC6 app layer may now be staged."
