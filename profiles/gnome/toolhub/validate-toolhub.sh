#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
T="$ROOT/profiles/gnome/toolhub"

fail(){ echo "[FAIL] $*" >&2; exit 1; }
ok(){ echo "[OK] $*"; }

[[ -x "$T/install-toolhub.sh" ]] || fail 'ToolHub rootfs installer missing/executable bit absent'
[[ -d "$T/app/toolhub" ]] || fail 'ToolHub Python package missing'
[[ -f "$T/app/com.spectre.ToolHub.desktop" ]] || fail 'ToolHub desktop entry missing'
[[ -f "$T/app/icons/spectre-toolhub-256.png" ]] || fail 'ToolHub app icon missing'
[[ -f "$T/app/icons/spectre-toolhub-brand.png" ]] || fail 'ToolHub brand artwork missing'
grep -q '^Name=Spectre ToolHub$' "$T/app/com.spectre.ToolHub.desktop" || fail 'desktop Name mismatch'
grep -q '^Exec=/usr/local/bin/spectre-toolhub gui$' "$T/app/com.spectre.ToolHub.desktop" || fail 'desktop Exec mismatch'
grep -q '^Icon=spectre-toolhub$' "$T/app/com.spectre.ToolHub.desktop" || fail 'desktop Icon mismatch'

python3 - "$T/app/toolhub" <<'PYCODE'
import pathlib, sys
root=pathlib.Path(sys.argv[1])
for path in root.glob('*.py'):
    compile(path.read_text(), str(path), 'exec')
PYCODE
ok 'ToolHub Python source compiles without writing bytecode'

python3 - "$T/app/toolhub/kali_catalog_snapshot.json" <<'PYSNAPSHOT'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
assert p.is_file(), "Bundled Kali snapshot missing"
snapshot = json.loads(p.read_text(encoding="utf-8"))
rows = snapshot["tools"]
assert len(rows) >= 750, "Bundled Kali snapshot smaller than release requirement"
names = [x["package"] for x in rows]
assert len(set(names)) == len(names), "Bundled Kali snapshot contains duplicates"
assert {"nmap", "wireshark"}.issubset(names), "Expected security tools missing"
assert snapshot["verified_signing_key"] == "827C8569F2518CC677FECA1AED65462EC8D5E4C5", "Wrong signing key"
print(f"[OK] Verified offline Kali snapshot: {len(rows)} tool packages")
PYSNAPSHOT

for pkg in podman passt uidmap slirp4netns fuse-overlayfs; do
    grep -qw "$pkg" "$ROOT/profiles/gnome/create-rootfs.sh" || fail "create-rootfs missing $pkg"
    grep -qw "$pkg" "$ROOT/profiles/gnome/build-live-iso.sh" || fail "build-live-iso missing $pkg"
done
ok 'rootless Podman prerequisites wired into both build paths'

grep -q 'SPECTRE_TOOLHUB_V1 BEGIN' "$ROOT/profiles/gnome/install-branding.sh" || fail 'install-branding ToolHub hook missing'
grep -q 'profiles/gnome/toolhub/validate-toolhub.sh' "$ROOT/profiles/gnome/validate-project.sh" || fail 'project ToolHub validation hook missing'
ok 'Spectre source integration hooks present'

# Deliberately ensure no Kali repo/image/archive is baked into source.
if grep -R -nE '(^|[[:space:]])deb[[:space:]].*kali|kali-rolling.*(tar|squashfs|oci)' "$T" --exclude='validate-toolhub.sh' >/tmp/spectre-toolhub-kali-bake.$$ 2>/dev/null; then
    cat /tmp/spectre-toolhub-kali-bake.$$
    rm -f /tmp/spectre-toolhub-kali-bake.$$
    fail 'Kali repository/image payload must not be baked into Spectre source'
fi
rm -f /tmp/spectre-toolhub-kali-bake.$$ 2>/dev/null || true
ok 'Kali stays on-demand and isolated from the base OS'

echo '[PASS] Spectre ToolHub source integration validation'
