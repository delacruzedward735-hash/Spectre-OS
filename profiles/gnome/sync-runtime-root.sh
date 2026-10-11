#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/config/release.conf"
TARGET="${1:-}"
MODE="${2:-template}"
[[ -n "$TARGET" ]] || { echo "usage: $0 /path/to/rootfs [mode]" >&2; exit 2; }
TARGET="$(readlink -f "$TARGET")"
[[ "$TARGET" != "/" && -d "$TARGET/etc" && -d "$TARGET/usr" ]] || {
  echo "[FAIL] refusing unsafe runtime target: $TARGET" >&2; exit 2;
}

echo "[Spectre] Synchronizing current source into runtime root ($MODE)..."
SPECTRE_GNOME_ROOTFS="$TARGET" \
SPECTRE_USER="${SPECTRE_USER:-spectre}" \
SPECTRE_SKIP_INITRAMFS_REFRESH=1 \
  "$ROOT/profiles/gnome/install-branding.sh"

"$ROOT/profiles/gnome/clean-product-rootfs.sh" "$TARGET"
"$ROOT/profiles/gnome/sanitize-runtime-state.sh" "$TARGET"

# Enforce NetworkManager ownership even for roots captured from older images.
sudo rm -f "$TARGET/etc/systemd/system/networking.service"
sudo ln -s /dev/null "$TARGET/etc/systemd/system/networking.service"

HASH="$($ROOT/profiles/gnome/runtime-source-hash.sh)"
cat <<STAMP | sudo tee "$TARGET/etc/spectre-build" >/dev/null
SPECTRE_BUILD_STAMP=1
RUNTIME_SOURCE_SHA256=$HASH
BUILD_ID=$SPECTRE_BUILD_ID
BUILD_MODE=$MODE
STAMP

echo "[ok] Runtime root synchronized: $HASH"
