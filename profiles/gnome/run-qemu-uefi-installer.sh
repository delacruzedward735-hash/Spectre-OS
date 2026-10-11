#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# SPECTRE_UEFI_INSTALLER_ISO_V22
#
# IMPORTANT ARCHITECTURE:
#
# spectre-gnome-uefi.img is a normal writable Spectre root disk:
#
#   ESP  -> SPECTRE_EFI
#   root -> SPECTRE_ROOT/ext4
#
# It is NOT a Debian Live/SquashFS environment and therefore must never
# be used as the source environment for the graphical installer.
#
# The Spectre installer intentionally requires:
#
#   /live/filesystem.squashfs
#
# from the installable Live ISO so that:
#
#   * the source media can be identified and protected
#   * the target cannot accidentally be the boot media
#   * the backend has an immutable installation source
#   * live-only packages/state can be removed deterministically
#
# run-qemu-iso.sh already provides:
#
#   OVMF UEFI firmware
#   Spectre Live ISO
#   disposable 48G QCOW2 target
#
# Therefore UEFI installer qualification delegates to that runner.

echo "[Spectre] UEFI installer qualification"
echo "[Spectre] Source: installable Spectre Live ISO"
echo "[Spectre] Firmware: OVMF / UEFI"
echo "[Spectre] Target: disposable QEMU QCOW2 disk"
echo

exec "$ROOT/profiles/gnome/run-qemu-iso.sh" "$@"
