#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOTFS="${SPECTRE_GNOME_ROOTFS:-$ROOT/rootfs-gnome}"
IMAGE="${SPECTRE_GNOME_IMAGE:-$ROOT/iso/spectre-gnome.img}"
SIZE="${SPECTRE_GNOME_IMAGE_SIZE:-16G}"

[[ -d "$ROOTFS/etc" ]] || {
    echo "GNOME rootfs not found: $ROOTFS" >&2
    echo "Run profiles/gnome/create-rootfs.sh first." >&2
    exit 1
}

command -v mkfs.ext4 >/dev/null 2>&1 || {
    echo "mkfs.ext4 is required (package: e2fsprogs)." >&2
    exit 1
}

mkdir -p "$(dirname "$IMAGE")"
truncate -s "$SIZE" "$IMAGE"
mkfs.ext4 -F -L SPECTRE_ROOT -d "$ROOTFS" "$IMAGE"

echo "[ok] Created sparse Spectre GNOME disk image:"
ls -lh "$IMAGE"
