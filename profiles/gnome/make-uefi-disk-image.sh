#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/config/release.conf"
ROOTFS="${SPECTRE_GNOME_ROOTFS:-$ROOT/rootfs-gnome}"
IMAGE="${SPECTRE_UEFI_IMAGE:-$ROOT/iso/spectre-gnome-uefi.img}"
SIZE="${SPECTRE_UEFI_IMAGE_SIZE:-24G}"
FORCE="${SPECTRE_FORCE:-0}"

[[ -d "$ROOTFS/etc" ]] || {
    echo "GNOME rootfs not found: $ROOTFS" >&2
    echo "Run profiles/gnome/create-rootfs.sh first." >&2
    exit 1
}

CURRENT_SOURCE_HASH="$("$ROOT/profiles/gnome/runtime-source-hash.sh")"
ROOT_STAMP="$ROOTFS/etc/spectre-build"
ROOT_SOURCE_HASH="$(sed -n 's/^RUNTIME_SOURCE_SHA256=//p' "$ROOT_STAMP" 2>/dev/null | head -1 || true)"
if [[ "$ROOT_SOURCE_HASH" != "$CURRENT_SOURCE_HASH" ]]; then
    echo "[FAIL] GNOME rootfs is stale or unstamped; refusing to publish an outdated image." >&2
    echo "       Run: ./profiles/gnome/sync-runtime-root.sh '$ROOTFS' uefi-template" >&2
    exit 2
fi

"$ROOT/profiles/gnome/verify-product-boundaries.sh" "$ROOTFS" || {
    echo "Run 'make gnome-clean' before building a publishable UEFI image." >&2
    exit 1
}

for cmd in sudo truncate parted losetup mkfs.ext4 mkfs.fat mount umount rsync grub-install; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "Missing host command: $cmd" >&2
        echo "On Linux Mint/Ubuntu install: sudo apt install parted dosfstools e2fsprogs rsync grub-efi-amd64-bin grub2-common" >&2
        exit 1
    }
done

kernel="$(find "$ROOTFS/boot" -maxdepth 1 -type f -name 'vmlinuz-*' 2>/dev/null | sort | tail -1 || true)"
[[ -n "$kernel" ]] || {
    echo "No Spectre kernel installed in $ROOTFS/boot." >&2
    echo "Run: ./profiles/gnome/install-kernel.sh ~/linux-7.1.8" >&2
    exit 1
}
krel="${kernel##*/vmlinuz-}"
initrd="$ROOTFS/boot/initrd.img-$krel"
[[ -f "$initrd" ]] || {
    echo "Matching initramfs not found: $initrd" >&2
    echo "Run profiles/gnome/install-kernel.sh after installing initramfs-tools in the rootfs." >&2
    exit 1
}

if [[ -e "$IMAGE" && "$FORCE" != "1" ]]; then
    echo "Image already exists: $IMAGE" >&2
    echo "Set SPECTRE_FORCE=1 to replace it." >&2
    exit 1
fi

mkdir -p "$(dirname "$IMAGE")"
rm -f "$IMAGE" "$IMAGE.source-sha256"
truncate -s "$SIZE" "$IMAGE"

# GPT: 512 MiB EFI System Partition + remaining ext4 root.
parted -s "$IMAGE" mklabel gpt
parted -s "$IMAGE" mkpart ESP fat32 1MiB 513MiB
parted -s "$IMAGE" set 1 esp on
parted -s "$IMAGE" name 1 SPECTRE_EFI
parted -s "$IMAGE" mkpart SPECTRE_ROOT ext4 513MiB 100%
parted -s "$IMAGE" name 2 SPECTRE_ROOT

loop=""
mount_dir=""
cleanup() {
    set +e
    if [[ -n "$mount_dir" ]]; then
        sudo umount -lf "$mount_dir/boot/efi" 2>/dev/null || true
        sudo umount -lf "$mount_dir" 2>/dev/null || true
        rmdir "$mount_dir" 2>/dev/null || true
    fi
    if [[ -n "$loop" ]]; then
        sudo losetup -d "$loop" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

loop="$(sudo losetup --find --show --partscan "$IMAGE")"
if command -v udevadm >/dev/null 2>&1; then sudo udevadm settle || true; fi
p1="${loop}p1"
p2="${loop}p2"
for _ in {1..20}; do
    [[ -b "$p1" && -b "$p2" ]] && break
    sleep 0.1
done
[[ -b "$p1" && -b "$p2" ]] || { echo "Partition devices did not appear for $loop" >&2; exit 1; }

sudo mkfs.fat -F 32 -n SPECTRE_EFI "$p1"
sudo mkfs.ext4 -F -L SPECTRE_ROOT "$p2"

mount_dir="$(mktemp -d)"
sudo mount "$p2" "$mount_dir"

printf '[Spectre] Copying GNOME root filesystem...\n'
sudo rsync -aHAX --numeric-ids --delete \
    --exclude='/boot/efi/***' \
    "$ROOTFS/" "$mount_dir/"

# Mount the EFI System Partition only after rsync has finished.
# This prevents rsync --delete from trying to remove a live mount point.
sudo mkdir -p "$mount_dir/boot/efi" "$mount_dir/boot/grub"
sudo mount "$p1" "$mount_dir/boot/efi"

printf '[Spectre] Installing removable-path x86_64 UEFI GRUB...\n'
sudo grub-install \
    --target=x86_64-efi \
    --efi-directory="$mount_dir/boot/efi" \
    --boot-directory="$mount_dir/boot" \
    --removable \
    --no-nvram \
    --recheck

# The removable-path GRUB EFI binary may otherwise drop to `grub>` because
# firmware/GRUB can start from the EFI System Partition without knowing where
# the Linux root filesystem's /boot/grub directory lives.
#
# Keep this bootstrap on the ESP deliberately tiny and label-based so the
# image still boots when QEMU/firmware changes the disk number.
printf '[Spectre] Installing portable GRUB bootstrap...\n'
sudo mkdir -p "$mount_dir/boot/efi/EFI/BOOT"
cat <<'EOF2' | sudo tee "$mount_dir/boot/efi/EFI/BOOT/grub.cfg" >/dev/null
# Spectre OS portable UEFI bootstrap
search --no-floppy --label SPECTRE_ROOT --set=root
set prefix=($root)/boot/grub

if [ -f ($root)/boot/grub/grub.cfg ]; then
    configfile ($root)/boot/grub/grub.cfg
else
    echo "Spectre OS boot configuration was not found."
    echo "Expected: ($root)/boot/grub/grub.cfg"
fi
EOF2

# grub-install's removable EFI image can use /boot/grub as its initial prefix
# on the EFI System Partition. Keep the same tiny bootstrap there too.
# This is the path required by firmware/GRUB combinations that otherwise stop
# at a bare `grub>` prompt with an error about /boot/ not being found.
sudo mkdir -p "$mount_dir/boot/efi/boot/grub"
cat <<'EOF2' | sudo tee "$mount_dir/boot/efi/boot/grub/grub.cfg" >/dev/null
# Spectre OS portable UEFI bootstrap (ESP /boot/grub fallback)
search --no-floppy --label SPECTRE_ROOT --set=root
set prefix=($root)/boot/grub

if [ -f ($root)/boot/grub/grub.cfg ]; then
    configfile ($root)/boot/grub/grub.cfg
else
    echo "Spectre OS boot configuration was not found."
    echo "Expected: ($root)/boot/grub/grub.cfg"
fi
EOF2

cat <<EOF2 | sudo tee "$mount_dir/boot/grub/grub.cfg" >/dev/null
set timeout=5
set default=0

if loadfont /boot/grub/fonts/unicode.pf2; then
    set gfxmode=auto
    insmod all_video
    terminal_output gfxterm
fi

menuentry '$SPECTRE_PRETTY_NAME' --class spectre --class gnu-linux {
    insmod part_gpt
    insmod ext2
    search --no-floppy --label SPECTRE_ROOT --set=root
    linux /boot/vmlinuz-$krel root=LABEL=SPECTRE_ROOT rw quiet splash loglevel=3 systemd.show_status=false rd.systemd.show_status=false udev.log_level=3 vt.global_cursor_default=0 plymouth.ignore-serial-consoles
    initrd /boot/initrd.img-$krel
}

menuentry '$SPECTRE_PRETTY_NAME - Text recovery' --class spectre --class gnu-linux {
    insmod part_gpt
    insmod ext2
    search --no-floppy --label SPECTRE_ROOT --set=root
    linux /boot/vmlinuz-$krel root=LABEL=SPECTRE_ROOT rw systemd.unit=multi-user.target console=tty1 loglevel=4
    initrd /boot/initrd.img-$krel
}

menuentry '$SPECTRE_PRETTY_NAME - Safe graphics' --class spectre --class gnu-linux {
    insmod part_gpt
    insmod ext2
    search --no-floppy --label SPECTRE_ROOT --set=root
    linux /boot/vmlinuz-$krel root=LABEL=SPECTRE_ROOT rw nomodeset systemd.unit=multi-user.target console=tty1 loglevel=4
    initrd /boot/initrd.img-$krel
}
EOF2

# Ensure the copied system mounts the partitions by filesystem labels.
cat <<'EOF2' | sudo tee "$mount_dir/etc/fstab" >/dev/null
LABEL=SPECTRE_ROOT  /         ext4  defaults,noatime  0  1
LABEL=SPECTRE_EFI   /boot/efi vfat  defaults,nofail,x-systemd.device-timeout=2s,umask=0077  0  2
EOF2

sync
cleanup
trap - EXIT INT TERM

printf '%s  runtime-source\n' "$CURRENT_SOURCE_HASH" > "$IMAGE.source-sha256"

echo
echo "[ok] Created bootable Spectre UEFI disk image:"
ls -lh "$IMAGE"
echo "     Kernel: $krel"
echo "     EFI:    FAT32 / SPECTRE_EFI"
echo "     Root:   ext4  / SPECTRE_ROOT"
echo "     Runtime source: $CURRENT_SOURCE_HASH"
echo
echo "Boot in QEMU with:"
echo "  ./profiles/gnome/run-qemu-uefi.sh"
