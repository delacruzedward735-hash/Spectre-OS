#!/usr/bin/env bash
set -euo pipefail

MODE=uefi
if [[ "${1:-}" == "--direct" || "${1:-}" == "--uefi" ]]; then
    MODE="${1#--}"
    shift
fi
CONFIG="${1:-$HOME/linux-7.1.8/.config}"
[[ -f "$CONFIG" ]] || { echo "Kernel config not found: $CONFIG" >&2; exit 1; }

# Core userspace/kernel contracts should be built in. Hardware/storage drivers
# may be modules in normal UEFI mode because Spectre installs a matching initramfs.
core_builtin=(
  CONFIG_DEVTMPFS CONFIG_DEVTMPFS_MOUNT CONFIG_PROC_FS CONFIG_SYSFS
  CONFIG_TMPFS CONFIG_TMPFS_POSIX_ACL CONFIG_PCI CONFIG_EFI_PARTITION CONFIG_NET CONFIG_UNIX
  CONFIG_INET CONFIG_VT CONFIG_VT_CONSOLE CONFIG_UNIX98_PTYS CONFIG_CGROUPS
  CONFIG_NAMESPACES CONFIG_SECCOMP CONFIG_SECCOMP_FILTER CONFIG_INOTIFY_USER
)
boot_drivers=(
  CONFIG_EXT4_FS CONFIG_VIRTIO CONFIG_VIRTIO_PCI CONFIG_VIRTIO_BLK
  CONFIG_DRM CONFIG_DRM_VIRTIO_GPU CONFIG_INPUT_EVDEV CONFIG_INPUT_KEYBOARD
  CONFIG_INPUT_MOUSE CONFIG_USB_SUPPORT CONFIG_USB_XHCI_HCD CONFIG_USB_HID
  CONFIG_HID_GENERIC CONFIG_VIRTIO_NET CONFIG_SERIAL_8250 CONFIG_SERIAL_8250_CONSOLE
)
recommended=(
  CONFIG_USER_NS CONFIG_PID_NS CONFIG_NET_NS CONFIG_UTS_NS CONFIG_IPC_NS
  CONFIG_FANOTIFY CONFIG_EFI CONFIG_EFIVAR_FS CONFIG_VFAT_FS CONFIG_TMPFS_XATTR CONFIG_SND CONFIG_SND_HDA_INTEL
  CONFIG_DRM_I915 CONFIG_DRM_AMDGPU CONFIG_DRM_NOUVEAU
)

value_of(){ grep -E "^$1=" "$CONFIG" | tail -1 | cut -d= -f2 || true; }
failed=0
printf 'Spectre GNOME kernel check (%s mode)\n\n' "$MODE"
printf '%-32s %s\n' 'KERNEL OPTION' 'STATUS'
printf '%-32s %s\n' '-------------' '------'
for opt in "${core_builtin[@]}"; do
    value="$(value_of "$opt")"
    if [[ "$value" == y ]]; then
        printf '%-32s %s\n' "$opt" 'OK (=y)'
    else
        printf '%-32s %s\n' "$opt" 'REQUIRED BUILT-IN (=y)'
        failed=1
    fi
done

printf '\n%-32s %s\n' 'BOOT / DEVICE OPTION' 'STATUS'
printf '%-32s %s\n' '--------------------' '------'
for opt in "${boot_drivers[@]}"; do
    value="$(value_of "$opt")"
    if [[ "$MODE" == direct ]]; then
        if [[ "$value" == y ]]; then
            printf '%-32s %s\n' "$opt" 'OK (=y)'
        else
            printf '%-32s %s\n' "$opt" 'DIRECT BOOT REQUIRES =y'
            failed=1
        fi
    else
        case "$value" in
            y) printf '%-32s %s\n' "$opt" 'OK (=y)' ;;
            m) printf '%-32s %s\n' "$opt" 'OK (=m; matching initramfs required)' ;;
            *) printf '%-32s %s\n' "$opt" 'MISSING'; failed=1 ;;
        esac
    fi
done

printf '\n%-32s %s\n' 'RECOMMENDED OPTION' 'STATUS'
printf '%-32s %s\n' '------------------' '------'
for opt in "${recommended[@]}"; do
    value="$(value_of "$opt")"
    case "$value" in
        y) printf '%-32s %s\n' "$opt" 'OK (=y)' ;;
        m) printf '%-32s %s\n' "$opt" 'OK (=m)' ;;
        *) printf '%-32s %s\n' "$opt" 'RECOMMENDED' ;;
    esac
done

if [[ "$failed" -ne 0 ]]; then
    echo
    echo "Spectre GNOME kernel requirements are not complete for $MODE mode."
    echo "Run: ./profiles/gnome/apply-kernel-config.sh ~/linux-7.1.8"
    exit 1
fi

echo
if [[ "$MODE" == uefi ]]; then
    echo 'Kernel configuration supports the Spectre UEFI + initramfs boot foundation.'
else
    echo 'Kernel configuration supports legacy direct-root QEMU boot.'
fi
