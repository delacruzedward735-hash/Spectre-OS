#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE="${SPECTRE_UEFI_IMAGE:-$ROOT/iso/spectre-gnome-uefi.img}"
RAM="${SPECTRE_GNOME_RAM:-6144}"
CPUS="${SPECTRE_GNOME_CPUS:-4}"

[[ -f "$IMAGE" ]] || { echo "UEFI disk image not found: $IMAGE" >&2; exit 1; }
CURRENT_SOURCE_HASH="$("$ROOT/profiles/gnome/runtime-source-hash.sh")"
IMAGE_SOURCE_HASH="$(awk 'NR==1{print $1}' "$IMAGE.source-sha256" 2>/dev/null || true)"
if [[ "${SPECTRE_ALLOW_STALE_IMAGE:-0}" != "1" && "$IMAGE_SOURCE_HASH" != "$CURRENT_SOURCE_HASH" ]]; then
    echo "[FAIL] UEFI image is stale or was built before runtime-source stamping." >&2
    echo "       Image source: ${IMAGE_SOURCE_HASH:-missing}" >&2
    echo "       Current:      $CURRENT_SOURCE_HASH" >&2
    echo "       Rebuild with: SPECTRE_FORCE=1 ./profiles/gnome/build-uefi.sh ~/linux-7.1.8" >&2
    exit 2
fi
command -v qemu-system-x86_64 >/dev/null 2>&1 || { echo "qemu-system-x86_64 is required." >&2; exit 1; }

find_first() {
    local p
    for p in "$@"; do
        [[ -f "$p" ]] && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}

CODE="${SPECTRE_OVMF_CODE:-$(find_first \
    /usr/share/OVMF/OVMF_CODE_4M.fd \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/edk2/ovmf/OVMF_CODE.fd || true)}"
VARS_TEMPLATE="${SPECTRE_OVMF_VARS:-$(find_first \
    /usr/share/OVMF/OVMF_VARS_4M.fd \
    /usr/share/OVMF/OVMF_VARS.fd \
    /usr/share/edk2/ovmf/OVMF_VARS.fd || true)}"
[[ -f "$CODE" && -f "$VARS_TEMPLATE" ]] || {
    echo "OVMF firmware was not found. On Mint/Ubuntu: sudo apt install ovmf" >&2
    exit 1
}

VARS="$ROOT/iso/OVMF_VARS_SPECTRE.fd"
if [[ ! -f "$VARS" || "${SPECTRE_RESET_NVRAM:-0}" == "1" ]]; then
    cp "$VARS_TEMPLATE" "$VARS"
fi

QEMU=(qemu-system-x86_64 -machine q35)
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    QEMU+=( -accel kvm -cpu host )
    echo "[Spectre] CPU: KVM / host"
else
    QEMU+=( -accel tcg -cpu max )
    echo "[Spectre] CPU: TCG / max"
fi

NET=( -device virtio-net-pci,netdev=net0 -netdev user,id=net0 )

echo "[Spectre] Note: -netdev and -device are QEMU options; do not run them as shell commands by themselves."

exec "${QEMU[@]}" \
  -drive if=pflash,format=raw,readonly=on,file="$CODE" \
  -drive if=pflash,format=raw,file="$VARS" \
  -drive if=none,id=spectredisk,file="$IMAGE",format=raw \
  -device virtio-blk-pci,drive=spectredisk,bootindex=0 \
  -vga virtio \
  -display gtk,gl=off \
  -device qemu-xhci \
  -device usb-kbd \
  -device usb-tablet \
  "${NET[@]}" \
  -boot order=c,menu=off \
  -m "$RAM" \
  -smp "$CPUS",sockets=1,cores="$CPUS",threads=1 \
  -serial stdio
