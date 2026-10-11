#!/usr/bin/env bash
# Verify Spectre 1.0 final core-only product boundary.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TARGET="${1:-${SPECTRE_GNOME_ROOTFS:-$ROOT/rootfs-gnome}}"
fail=0
ok(){ printf '[OK]   %s\n' "$*"; }
bad(){ printf '[FAIL] %s\n' "$*" >&2; fail=1; }

legacy_source="$({ grep -RIniE 'swift[[:space:]_.-]*share|appsweep|com[.]swiftshare' \
  "$ROOT/Makefile" "$ROOT/scripts" "$ROOT/profiles/gnome" \
  --exclude='clean-product-rootfs.sh' --exclude='release-check.sh' \
  --exclude='verify-live-iso.sh' --exclude='verify-product-boundaries.sh' \
  --exclude='validate-project.sh' --exclude='spectre-installed-health' \
  --exclude='*.backup*' --exclude='*.before-*' 2>/dev/null || true; } \
  | grep -v '/profiles/gnome/personal-apps/README.md' || true)"
if [[ -n "$legacy_source" ]]; then
  printf '%s\n' "$legacy_source" >&2
  bad 'legacy personal-app integration remains in active Spectre source'
else
  ok 'active Spectre source is core-only; legacy personal-app integration retired'
fi

if [[ -d "$TARGET/etc" ]]; then
  [[ ! -e "$TARGET/usr/share/spectre/personal-apps.manifest" ]] || bad 'legacy personal-app manifest exists in core-only root'
  hit="$(find "$TARGET" -xdev \( -iname '*swiftshare*' -o -iname '*appsweep*' \) -print -quit 2>/dev/null || true)"
  [[ -z "$hit" ]] || bad "legacy personal-product artifact exists in core-only root: ${hit#$TARGET}"
  managed="$TARGET/usr/share/spectre/managed-apps.manifest"
  if [[ -f "$managed" ]]; then
    if grep -vE '^[[:space:]]*(#|$)' "$managed" | grep -q .; then
      bad 'managed-app registry is non-empty in Spectre 1.0 final core image'
    else
      ok 'managed-app framework present with empty production registry'
    fi
  else
    ok 'core engineering root contains no staged managed-app manifest yet'
  fi
else
  printf '[INFO] rootfs not present; source-boundary check only (%s)\n' "$TARGET"
fi

((fail == 0)) || exit 1
echo '[ok] Spectre core-only product-boundary verification passed.'
