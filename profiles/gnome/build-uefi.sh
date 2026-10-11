#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KERNEL_TREE="${1:-$HOME/linux-7.1.8}"
TARGET="${SPECTRE_GNOME_ROOTFS:-$ROOT/rootfs-gnome}"
SPECTRE_SUDO_KEEPALIVE_PID=""

start_host_privilege_session() {
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        return 0
    fi
    command -v sudo >/dev/null 2>&1 || {
        echo "[Spectre] ERROR: sudo is required on the build host." >&2
        exit 1
    }
    echo "[Spectre] Host privilege is required for debootstrap, mounts, loop devices and GRUB."
    echo "[Spectre] Authenticate once; the build will keep this sudo session alive and will not repeatedly prompt."
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

trap stop_host_privilege_session EXIT INT TERM
start_host_privilege_session

"$ROOT/profiles/gnome/check-kernel.sh" --uefi "$KERNEL_TREE/.config"

rootfs_complete() {
    [[ -f "$TARGET/etc/os-release" ]] &&
    [[ -x "$TARGET/usr/bin/gnome-shell" ]] &&
    [[ -x "$TARGET/usr/bin/libreoffice" ]] &&
    [[ -f "$TARGET/etc/sudoers.d/90-spectre-live" ]] &&
    [[ -f "$TARGET/etc/gdm3/daemon.conf" ]] &&
    grep -q '^spectre:' "$TARGET/etc/passwd" 2>/dev/null
}

reset_incomplete_rootfs() {
    local safe_prefix="$ROOT/"
    case "$TARGET/" in
        "$safe_prefix"*) ;;
        *)
            echo "[Spectre] ERROR: refusing privileged cleanup outside $ROOT: $TARGET" >&2
            exit 2
            ;;
    esac
    echo "[Spectre] Incomplete/interrupted rootfs detected: $TARGET"
    [[ "${SPECTRE_FORCE:-0}" == 1 ]] || {
        echo "[Spectre] Remove it manually or rerun with SPECTRE_FORCE=1 for guarded cleanup." >&2
        exit 2
    }
    for mountpoint in "$TARGET/dev/pts" "$TARGET/dev" "$TARGET/proc" "$TARGET/sys"; do
        sudo umount -lf -- "$mountpoint" 2>/dev/null || true
    done
    sudo rm -rf --one-file-system -- "$TARGET"
    mkdir -p "$TARGET"
    echo "[Spectre] Cleared interrupted rootfs safely; starting a clean production rootfs build."
}

if ! rootfs_complete; then
    if [[ -e "$TARGET/etc/os-release" || -n "$(find "$TARGET" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
        reset_incomplete_rootfs
    fi
    SPECTRE_ROOTFS_ACCOUNT_MODE=live-template SPECTRE_GNOME_ROOTFS="$TARGET" "$ROOT/profiles/gnome/create-rootfs.sh"
fi

# A pre-existing rootfs is a build cache, not the source of truth. Reinstall
# the current Spectre runtime before kernel/image assembly on every build.
"$ROOT/profiles/gnome/sync-runtime-root.sh" "$TARGET" uefi-template
SPECTRE_GNOME_ROOTFS="$TARGET" "$ROOT/profiles/gnome/install-kernel.sh" "$KERNEL_TREE"
SPECTRE_GNOME_ROOTFS="$TARGET" "$ROOT/profiles/gnome/verify.sh"
SPECTRE_GNOME_ROOTFS="$TARGET" "$ROOT/profiles/gnome/make-uefi-disk-image.sh"

echo
echo "[ok] Spectre GNOME UEFI image is ready."
echo "Boot it with: ./profiles/gnome/run-qemu-uefi.sh"
