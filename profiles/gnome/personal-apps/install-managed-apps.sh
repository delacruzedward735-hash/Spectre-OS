#!/usr/bin/env bash
# Install registry-driven Spectre applications into a staged root filesystem.
set -euo pipefail
APPROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-}"
[[ -n "$TARGET" ]] || { echo "usage: $0 /path/to/rootfs" >&2; exit 2; }
TARGET="$(readlink -f "$TARGET")"
[[ "$TARGET" != "/" && -d "$TARGET/etc" && -d "$TARGET/usr" ]] || { echo "Refusing unsafe rootfs target: $TARGET" >&2; exit 2; }

"$APPROOT/validate-managed-apps.sh"
sudo install -d -m 0755 "$TARGET/opt/codedev/apps" "$TARGET/usr/share/spectre" "$TARGET/usr/share/applications" "$TARGET/usr/bin" \
  "$TARGET/usr/share/icons/hicolor/256x256/apps" "$TARGET/usr/share/icons/hicolor/scalable/apps"

# Remove artifacts from apps that were present in the previous staged image. This
# makes reused engineering roots deterministic when an app is disabled/removed.
OLD_MANIFEST="$TARGET/usr/share/spectre/managed-apps.manifest"
if [[ -f "$OLD_MANIFEST" ]]; then
  while IFS=$'\t' read -r old_id _old_version _old_state _old_runtime _old_dir; do
    [[ "$old_id" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] || continue
    sudo rm -rf "$TARGET/opt/codedev/apps/$old_id"
    sudo rm -f "$TARGET/usr/bin/$old_id" "$TARGET/usr/share/applications/$old_id.desktop" \
      "$TARGET/usr/share/icons/hicolor/256x256/apps/$old_id.png" \
      "$TARGET/usr/share/icons/hicolor/scalable/apps/$old_id.svg"
  done < <(grep -vE '^[[:space:]]*(#|$)' "$OLD_MANIFEST" || true)
fi

sudo install -m 0644 "$APPROOT/registry.tsv" "$OLD_MANIFEST"

mapfile -t ROWS < <(grep -vE '^[[:space:]]*(#|$)' "$APPROOT/registry.tsv" || true)
for row in "${ROWS[@]}"; do
  IFS=$'\t' read -r app_id version state runtime app_dir <<<"$row"
  [[ "$state" == enabled ]] || { printf '[INFO] managed app disabled: %s\n' "$app_id"; continue; }
  SRC="$APPROOT/apps/$app_dir"

  mapfile -d '' -t META < <(python3 - "$APPROOT" "$SRC/app.conf" <<'PY'
from pathlib import Path
import importlib.util, sys
sys.dont_write_bytecode = True
root=Path(sys.argv[1]); conf=Path(sys.argv[2])
spec=importlib.util.spec_from_file_location('managed_app', root/'managed_app.py'); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
d=m.parse_conf(conf)
keys=['APP_ID','APP_NAME','APP_VERSION','APP_STATE','APP_RUNTIME','APP_ENTRY','APP_COMMAND','APP_LAUNCHER','APP_ICON','APP_ICON_FILE','APP_COMMENT','APP_CATEGORIES','APP_KEYWORDS','APP_TERMINAL','APP_REQUIREMENTS']
for k in keys:
    sys.stdout.buffer.write(d[k].encode()+b'\0')
PY
)
  [[ ${#META[@]} -eq 15 ]] || { echo "[FAIL] metadata parser failed for $app_id" >&2; exit 1; }
  APP_ID="${META[0]}"; APP_NAME="${META[1]}"; APP_VERSION="${META[2]}"; APP_RUNTIME="${META[4]}"; APP_ENTRY="${META[5]}"
  APP_ICON="${META[8]}"; APP_ICON_FILE="${META[9]}"; APP_COMMENT="${META[10]}"; APP_CATEGORIES="${META[11]}"; APP_KEYWORDS="${META[12]}"; APP_TERMINAL="${META[13]}"; APP_REQUIREMENTS="${META[14]}"

  DEST="$TARGET/opt/codedev/apps/$APP_ID"
  sudo rm -rf "$DEST"
  sudo install -d -m 0755 "$DEST"
  sudo rsync -a --delete "$SRC/payload/" "$DEST/"

  case "$APP_RUNTIME" in
    python-venv)
      sudo chroot "$TARGET" /bin/bash -euc '
        export DEBIAN_FRONTEND=noninteractive
        if ! command -v python3 >/dev/null || ! python3 -m venv --help >/dev/null 2>&1; then
          apt-get update
          apt-get install -y --no-install-recommends python3 python3-venv ca-certificates
          apt-get clean
          rm -rf /var/lib/apt/lists/*
          install -d -m 0755 /var/lib/apt/lists/partial
        fi
      '
      sudo chroot "$TARGET" /bin/bash -euc "rm -rf '/opt/codedev/apps/$APP_ID/.venv'; python3 -m venv '/opt/codedev/apps/$APP_ID/.venv'"
      if [[ -n "$APP_REQUIREMENTS" ]]; then
        sudo install -m 0644 "$SRC/$APP_REQUIREMENTS" "$DEST/requirements.spectre.lock"
        sudo chroot "$TARGET" /bin/bash -euc "'/opt/codedev/apps/$APP_ID/.venv/bin/python' -m pip install --disable-pip-version-check --no-cache-dir -r '/opt/codedev/apps/$APP_ID/requirements.spectre.lock'"
      fi
      cat <<EOF | sudo tee "$TARGET/usr/bin/$APP_ID" >/dev/null
#!/bin/sh
cd /opt/codedev/apps/$APP_ID
exec /opt/codedev/apps/$APP_ID/.venv/bin/python /opt/codedev/apps/$APP_ID/$APP_ENTRY "\$@"
EOF
      ;;
    python-system)
      sudo chroot "$TARGET" /bin/bash -euc 'command -v python3 >/dev/null || { apt-get update; apt-get install -y --no-install-recommends python3; apt-get clean; rm -rf /var/lib/apt/lists/*; install -d -m 0755 /var/lib/apt/lists/partial; }'
      cat <<EOF | sudo tee "$TARGET/usr/bin/$APP_ID" >/dev/null
#!/bin/sh
cd /opt/codedev/apps/$APP_ID
exec /usr/bin/python3 /opt/codedev/apps/$APP_ID/$APP_ENTRY "\$@"
EOF
      ;;
    native-binary)
      sudo chmod 0755 "$DEST/$APP_ENTRY"
      cat <<EOF | sudo tee "$TARGET/usr/bin/$APP_ID" >/dev/null
#!/bin/sh
cd /opt/codedev/apps/$APP_ID
exec /opt/codedev/apps/$APP_ID/$APP_ENTRY "\$@"
EOF
      ;;
    *) echo "[FAIL] unsupported managed runtime: $APP_RUNTIME" >&2; exit 1 ;;
  esac
  sudo chmod 0755 "$TARGET/usr/bin/$APP_ID"

  cat <<EOF | sudo tee "$TARGET/usr/share/applications/$APP_ID.desktop" >/dev/null
[Desktop Entry]
Type=Application
Name=$APP_NAME
Comment=$APP_COMMENT
Exec=/usr/bin/$APP_ID
Icon=$APP_ICON
Terminal=$APP_TERMINAL
Categories=$APP_CATEGORIES
Keywords=$APP_KEYWORDS
StartupNotify=true
EOF

  if [[ -n "$APP_ICON_FILE" ]]; then
    case "$APP_ICON_FILE" in
      *.png) sudo install -m 0644 "$SRC/$APP_ICON_FILE" "$TARGET/usr/share/icons/hicolor/256x256/apps/$APP_ID.png" ;;
      *.svg) sudo install -m 0644 "$SRC/$APP_ICON_FILE" "$TARGET/usr/share/icons/hicolor/scalable/apps/$APP_ID.svg" ;;
    esac
  fi

  # Compile Python sources without executing application code.
  if [[ "$APP_RUNTIME" == python-* ]]; then
    sudo chroot "$TARGET" /bin/bash -euc "find '/opt/codedev/apps/$APP_ID' -path '*/.venv' -prune -o -name '*.py' -type f -print0 | xargs -0 -r /usr/bin/python3 -m py_compile"
  fi
  printf '[OK]   managed app staged: %s %s (%s)\n' "$APP_ID" "$APP_VERSION" "$APP_RUNTIME"
done

# Fail if app IDs appear in OS-wide privilege/startup policy. This scans only
# registered IDs and therefore scales as more CodeDev apps are added.
while IFS=$'\t' read -r app_id _version state _runtime _dir; do
  [[ "$state" == enabled ]] || continue
  for forbidden in "$TARGET/etc/xdg/autostart" "$TARGET/etc/systemd/system" "$TARGET/usr/lib/systemd/system" "$TARGET/etc/polkit-1/rules.d" "$TARGET/etc/sudoers.d" "$TARGET/etc/ufw"; do
    [[ -d "$forbidden" ]] || continue
    if sudo grep -RIlE "(^|[^[:alnum:]_.-])${app_id}([^[:alnum:]_.-]|$)" "$forbidden" 2>/dev/null | grep -q .; then
      echo "[FAIL] managed app $app_id acquired privileged/autostart integration under $forbidden" >&2
      exit 1
    fi
  done
done < <(grep -vE '^[[:space:]]*(#|$)' "$APPROOT/registry.tsv" || true)

sudo chroot "$TARGET" /bin/bash -euc '
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -f -t /usr/share/icons/hicolor >/dev/null 2>&1 || true
'
printf '[ok] Spectre managed application layer installed.\n'
