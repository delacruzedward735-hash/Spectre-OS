#!/usr/bin/env bash
set -Eeuo pipefail

TARGET="${1:-/}"
GNOME_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WALLPAPER_SRC="$GNOME_DIR/branding/backgrounds/spectre-login-blur.jpg"
LOGO_SRC="$GNOME_DIR/branding/pixmaps/spectre-logo.png"
GDM_LOGO_SRC="$GNOME_DIR/branding/gdm/spectre-gdm-compact.png"

fail(){ printf '[Spectre][FAIL] %s\n' "$*" >&2; exit 1; }
ok(){ printf '[Spectre][OK] %s\n' "$*"; }

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    ROOTCMD=()
else
    command -v sudo >/dev/null 2>&1 || fail "sudo is required to write the staged target root"
    ROOTCMD=(sudo)
fi

root_do() {
    "${ROOTCMD[@]}" "$@"
}

[[ -d "$TARGET" ]] || fail "target root does not exist: $TARGET"
[[ -s "$WALLPAPER_SRC" ]] || fail "bundled Spectre login wallpaper missing: $WALLPAPER_SRC"
[[ -s "$LOGO_SRC" ]] || fail "Spectre source logo missing: $LOGO_SRC"
[[ -s "$GDM_LOGO_SRC" ]] || fail "Dedicated compact GDM logo missing: $GDM_LOGO_SRC"

for c in gresource glib-compile-resources python3; do
    command -v "$c" >/dev/null 2>&1 || fail "missing host command: $c"
done

GRES="$TARGET/usr/share/gnome-shell/gnome-shell-theme.gresource"
[[ -s "$GRES" ]] || fail "GNOME Shell theme resource missing in target: $GRES"

# The installer-ISO staging root is deliberately root-owned. All target-root
# mutations must therefore cross the existing build privilege boundary instead
# of trying to write as the unprivileged build user.
root_do install -Dm0644 "$WALLPAPER_SRC" \
    "$TARGET/usr/share/backgrounds/spectre/spectre-login-blur.jpg"

root_do install -Dm0644 "$LOGO_SRC" \
    "$TARGET/usr/share/pixmaps/spectre-logo.png"

# GDM alone uses a compact logo; the original branding asset stays intact.
root_do install -Dm0644 "$GDM_LOGO_SRC" \
    "$TARGET/usr/share/pixmaps/spectre-gdm-compact.png"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SRC="$TMP/src"
mkdir -p "$SRC"

LIST="$TMP/resources.list"
gresource list "$GRES" > "$LIST"
[[ -s "$LIST" ]] || fail "GNOME Shell resource list is empty"

CSS_RES="$(
    grep -E '/(gnome-shell|stylesheet)\.css$' "$LIST" | head -1 || true
)"
if [[ -z "$CSS_RES" ]]; then
    CSS_RES="$(grep -E '\.css$' "$LIST" | head -1 || true)"
fi
[[ -n "$CSS_RES" ]] || fail "no CSS resource found inside GNOME Shell theme"

while IFS= read -r RES; do
    [[ -n "$RES" ]] || continue
    REL="${RES#/}"
    OUT="$SRC/$REL"
    mkdir -p "$(dirname "$OUT")"
    gresource extract "$GRES" "$RES" > "$OUT"
done < "$LIST"

CSS_FILE="$SRC/${CSS_RES#/}"
[[ -s "$CSS_FILE" ]] || fail "failed to extract GNOME Shell CSS: $CSS_RES"

CSS_DIR="$(dirname "${CSS_RES#/}")"
WALL_REL="$CSS_DIR/spectre-login-blur.jpg"
WALL_RES="/$WALL_REL"
install -Dm0644 "$WALLPAPER_SRC" "$SRC/$WALL_REL"

python3 - "$CSS_FILE" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
s = p.read_text(errors="surrogateescape")
s = re.sub(
    r'\n?/\* SPECTRE_GDM_LOCKSCREEN_SOURCE_V1 BEGIN \*/.*?'
    r'/\* SPECTRE_GDM_LOCKSCREEN_SOURCE_V1 END \*/\n?',
    '\n',
    s,
    flags=re.S,
)
p.write_text(s)
PY

cat >> "$CSS_FILE" <<EOF

/* SPECTRE_GDM_LOCKSCREEN_SOURCE_V1 BEGIN */
#lockDialogGroup {
    background-color: #030812;
    background-image: url("resource://$WALL_RES");
    background-repeat: no-repeat;
    background-position: center;
    background-size: cover;
}
/* SPECTRE_GDM_LOCKSCREEN_SOURCE_V1 END */
EOF

XML="$TMP/gnome-shell-theme.gresource.xml"
python3 - "$SRC" "$XML" <<'PY'
from pathlib import Path
from xml.sax.saxutils import escape
import sys

src = Path(sys.argv[1])
xml = Path(sys.argv[2])
files = sorted(
    p.relative_to(src).as_posix()
    for p in src.rglob("*")
    if p.is_file()
)
with xml.open("w") as f:
    f.write('<?xml version="1.0" encoding="UTF-8"?>\n')
    f.write("<gresources>\n")
    f.write('  <gresource prefix="/">\n')
    for rel in files:
        f.write(f"    <file>{escape(rel)}</file>\n")
    f.write("  </gresource>\n")
    f.write("</gresources>\n")
PY

NEW="$TMP/gnome-shell-theme.gresource"
glib-compile-resources \
    --target="$NEW" \
    --sourcedir="$SRC" \
    "$XML"

[[ -s "$NEW" ]] || fail "compiled GNOME Shell resource is empty"

while IFS= read -r RES; do
    [[ -n "$RES" ]] || continue
    gresource list "$NEW" | grep -Fqx "$RES" \
        || fail "recompiled resource lost original path: $RES"
done < "$LIST"

gresource list "$NEW" | grep -Fqx "$WALL_RES" \
    || fail "Spectre login wallpaper is not embedded in compiled resource"

TMP_CSS="$TMP/verify.css"
gresource extract "$NEW" "$CSS_RES" > "$TMP_CSS"
grep -Fq 'SPECTRE_GDM_LOCKSCREEN_SOURCE_V1 BEGIN' "$TMP_CSS" \
    || fail "Spectre GDM CSS marker missing from compiled resource"

root_do install -m0644 "$NEW" "$GRES"
ok "GNOME Shell/GDM wallpaper resource patched transactionally"

# Build GDM policy files in our private temporary directory, then atomically
# install them into the root-owned staged image. Python never opens a target
# file for writing directly.
GDM_DEFAULTS="$TARGET/etc/gdm3/greeter.dconf-defaults"
TMP_DEFAULTS="$TMP/greeter.dconf-defaults"

if [[ -f "$GDM_DEFAULTS" ]]; then
    cp "$GDM_DEFAULTS" "$TMP_DEFAULTS"
else
    : > "$TMP_DEFAULTS"
fi

python3 - "$TMP_DEFAULTS" <<'PY'
from pathlib import Path
import configparser, sys

p = Path(sys.argv[1])
cfg = configparser.ConfigParser(interpolation=None, strict=False)
cfg.optionxform = str
if p.exists() and p.stat().st_size:
    try:
        cfg.read(p)
    except Exception:
        cfg = configparser.ConfigParser(interpolation=None, strict=False)
        cfg.optionxform = str

wanted = {
    "org/gnome/login-screen": {
        "logo": "'/usr/share/pixmaps/spectre-gdm-compact.png'",
    },
    "org/gnome/desktop/interface": {
        "color-scheme": "'prefer-dark'",
        "gtk-theme": "'Adwaita-dark'",
    },
    "org/gnome/desktop/background": {
        "picture-uri": "'file:///usr/share/backgrounds/spectre/spectre-login-blur.jpg'",
        "picture-uri-dark": "'file:///usr/share/backgrounds/spectre/spectre-login-blur.jpg'",
        "picture-options": "'zoom'",
        "primary-color": "'#030812'",
    },
}
for section, values in wanted.items():
    if not cfg.has_section(section):
        cfg.add_section(section)
    for key, value in values.items():
        cfg.set(section, key, value)

with p.open("w") as f:
    cfg.write(f, space_around_delimiters=False)
PY

root_do install -Dm0644 "$TMP_DEFAULTS" "$GDM_DEFAULTS"

TMP_GDM_FRAGMENT="$TMP/10-spectre-identity"
cat > "$TMP_GDM_FRAGMENT" <<'EOF'
[org/gnome/login-screen]
logo='/usr/share/pixmaps/spectre-gdm-compact.png'

[org/gnome/desktop/interface]
color-scheme='prefer-dark'
gtk-theme='Adwaita-dark'

[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/spectre/spectre-login-blur.jpg'
picture-uri-dark='file:///usr/share/backgrounds/spectre/spectre-login-blur.jpg'
picture-options='zoom'
primary-color='#030812'
EOF

root_do install -Dm0644 "$TMP_GDM_FRAGMENT" \
    "$TARGET/etc/dconf/db/gdm.d/10-spectre-identity"

if [[ -x "$TARGET/usr/bin/dconf" ]]; then
    root_do chroot "$TARGET" /usr/bin/dconf update
else
    fail "target dconf executable missing; refusing an uncompiled GDM policy"
fi

ok "Spectre GDM logo/background policy compiled"
ok "permanent Spectre login identity complete"
