#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/config/release.conf"
failed=0
warned=0
ok(){ printf '[OK]   %-24s %s\n' "$1" "${2:-}"; }
miss(){ printf '[MISS] %-24s %s\n' "$1" "${2:-}"; failed=1; }
warn(){ printf '[WARN] %-24s %s\n' "$1" "${2:-}"; warned=1; }

printf '%s host readiness\n\n' "$SPECTRE_PRETTY_NAME"
for cmd in debootstrap qemu-system-x86_64 mkfs.ext4 mkfs.fat parted rsync grub-install losetup python3; do
  if command -v "$cmd" >/dev/null 2>&1; then ok "$cmd" "$(command -v "$cmd")"; else miss "$cmd"; fi
done

if [[ -r /dev/kvm && -w /dev/kvm ]]; then ok KVM '/dev/kvm usable'; else warn KVM 'not usable; QEMU will use slower TCG'; fi

ovmf=''
for p in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd; do
  if [[ -f "$p" ]]; then ovmf="$p"; break; fi
done
[[ -n "$ovmf" ]] && ok OVMF "$ovmf" || miss OVMF 'install package: ovmf'

free_kb="$(df -Pk . 2>/dev/null | awk 'NR==2 {print $4}')"
if [[ "$free_kb" =~ ^[0-9]+$ ]]; then
  free_gib=$((free_kb / 1024 / 1024))
  if (( free_gib >= 20 )); then ok 'free disk' "${free_gib} GiB"; else warn 'free disk' "${free_gib} GiB; 20+ GiB recommended"; fi
fi

if command -v qemu-system-x86_64 >/dev/null 2>&1; then
  if qemu-system-x86_64 -device help 2>/dev/null | grep -qE 'virtio-gpu-gl-pci|virtio-vga-gl'; then
    ok VirGL 'GL-capable Virtio GPU exposed by QEMU'
  else
    warn VirGL 'not exposed; software rendering fallback will be used'
  fi
fi

printf '\n'
if (( failed )); then
  echo 'Host is missing required build/runtime tools.'
  echo 'Linux Mint/Ubuntu:'
  echo '  sudo apt install debootstrap e2fsprogs qemu-system-x86 parted dosfstools rsync grub-efi-amd64-bin grub2-common ovmf'
  exit 1
fi
if (( warned )); then
  echo 'Host has all required tools, with one or more optional performance/capacity warnings.'
else
  echo 'Host is ready for the Spectre GNOME UEFI build.'
fi
