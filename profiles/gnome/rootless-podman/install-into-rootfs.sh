#!/usr/bin/env bash
# Runs during Spectre ISO assembly, never on the Zorin host root filesystem.
set -Eeuo pipefail
umask 022
[[ $# == 1 ]] || { echo '[STOP] Expected isolated stage root path' >&2; exit 2; }
ROOT="$(readlink -m -- "$1")"
[[ "$ROOT" != / && -d "$ROOT/etc" && -f "$ROOT/etc/os-release" && -d "$ROOT/usr" ]] || {
  echo '[STOP] Invalid staging root, refusing to install provisioner' >&2; exit 1;
}
[[ ! -L "$1" ]] || { echo '[STOP] Symlinked stage root not allowed' >&2; exit 1; }
[[ $(id -u) == 0 ]] || { echo '[STOP] Staging hook requires root' >&2; exit 1; }
for binary in usr/bin/python3 usr/bin/podman usr/bin/newuidmap usr/bin/newgidmap usr/sbin/usermod; do
  [[ -x "$ROOT/$binary" ]] || { echo "[STOP] Required Podman/account tool missing in stage: $binary" >&2; exit 1; }
done
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# Do not overwrite unrelated distro services if the name is already used.
UNIT="$ROOT/etc/systemd/system/spectre-rootless-podman-subids.service"
PROG="$ROOT/usr/local/libexec/spectre-rootless-podman-provision.py"
if [[ -e "$UNIT" || -e "$PROG" ]]; then
  cmp -s "$HERE/spectre-rootless-podman-subids.service" "$UNIT" &&
  cmp -s "$HERE/spectre-rootless-podman-provision.py" "$PROG" || {
    echo '[STOP] Conflicting provisioner already present in stage' >&2; exit 1;
  }
fi
install -d -m 0755 "$ROOT/usr/local/libexec" "$ROOT/etc/systemd/system/multi-user.target.wants"
install -d -m 0700 "$ROOT/var/backups/spectre-rootless-podman"
install -m 0755 "$HERE/spectre-rootless-podman-provision.py" "$PROG"
install -m 0644 "$HERE/spectre-rootless-podman-subids.service" "$UNIT"
for map in subuid subgid; do
  [[ ! -L "$ROOT/etc/$map" ]] || { echo "[STOP] Symlinked $map in stage" >&2; exit 1; }
  if [[ ! -e "$ROOT/etc/$map" ]]; then
    install -m 0644 /dev/null "$ROOT/etc/$map"
  fi
done
LINK="$ROOT/etc/systemd/system/multi-user.target.wants/spectre-rootless-podman-subids.service"
if [[ -e "$LINK" || -L "$LINK" ]]; then
  [[ -L "$LINK" && "$(readlink -- "$LINK")" == '../spectre-rootless-podman-subids.service' ]] || {
    echo '[STOP] Conflicting service activation link in staged OS' >&2; exit 1;
  }
else
  ln -s ../spectre-rootless-podman-subids.service "$LINK"
fi
# Verify non-empty and exact payload rather than promising runtime success.
cmp -s "$HERE/spectre-rootless-podman-provision.py" "$PROG"
cmp -s "$HERE/spectre-rootless-podman-subids.service" "$UNIT"
echo '[PASS] Permanent rootless Podman UID/GID service embedded in Spectre stage root'
