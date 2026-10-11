# Spectre OS 0.9 — GNOME profile

This is the primary desktop track for Spectre OS. It keeps the custom Spectre
kernel while using a complete Debian 13 (trixie) userspace for systemd, D-Bus,
NetworkManager, Mesa, PipeWire, GDM, Wayland/Mutter and GNOME.

The original BusyBox + direct DRM/KMS environment remains in the project as the
small recovery/developer track.

## Supported boot paths

Spectre can now be tested through two boot paths:

1. **Normal UEFI boot** — OVMF/firmware -> GRUB -> Spectre kernel + initramfs ->
   systemd -> GDM -> GNOME. This is the recommended path.
2. **Direct-kernel QEMU boot** — QEMU loads `bzImage` directly. This remains a
   fast engineering/debug path.

The UEFI image has a GPT partition table, a FAT32 EFI System Partition and a
persistent ext4 root filesystem.

## Visual direction

The GNOME profile is preconfigured to match the Spectre concept:

- deep navy/black desktop and electric blue/cyan accents
- Spectre hooded-figure wallpaper
- Applications and Places on the top panel
- centered clock and four fixed workspaces
- fixed vertical left dock
- dark translucent GNOME Shell UI
- right-side live network and system-monitor cards with a panel fallback
- Spectre terminal colors and shell prompt
- Papirus-Dark icons
- first-login Spectre Welcome app
- optional right-side Spectre system HUD
- GNOME-native window snapping and keyboard navigation

## 1. Host dependencies

Linux Mint / Ubuntu development host:

```bash
sudo apt update
sudo apt install \
  debootstrap e2fsprogs qemu-system-x86 build-essential \
  parted dosfstools rsync grub-efi-amd64-bin grub2-common ovmf
```

The rootfs build downloads several GB of packages.

## 2. Prepare the custom kernel

Recommended UEFI check:

```bash
./profiles/gnome/check-kernel.sh --uefi ~/linux-7.1.8/.config
```

If required options are missing:

```bash
./profiles/gnome/apply-kernel-config.sh ~/linux-7.1.8
cd ~/linux-7.1.8
make -j"$(nproc)"
```

The legacy direct-root boot can be checked more strictly with:

```bash
./profiles/gnome/check-kernel.sh --direct ~/linux-7.1.8/.config
```

## 3. Build the GNOME userspace

```bash
./profiles/gnome/create-rootfs.sh
```

It creates `rootfs-gnome/`. The default desktop user is `spectre` and the build
prompts for a password.

For temporary unattended VM builds only:

```bash
SPECTRE_PASSWORD='temporary-password' ./profiles/gnome/create-rootfs.sh
```

## 4. Install your Spectre kernel and matching initramfs

```bash
./profiles/gnome/install-kernel.sh ~/linux-7.1.8
```

This installs the kernel, modules when enabled, System.map/config, runs depmod,
and generates the matching initramfs.

## 5. Verify the rootfs

```bash
make gnome-clean
./profiles/gnome/verify.sh
make gnome-boundaries
```

`gnome-clean` removes deferred personal-product artifacts and resets mutable
development-user desktop state before a release image is created.

Project scripts can also be syntax-checked without building the rootfs:

```bash
./profiles/gnome/validate-project.sh
```

## 6. Build the normal UEFI disk image

```bash
./profiles/gnome/make-uefi-disk-image.sh
```

Default output:

```text
iso/spectre-gnome-uefi.img
```

If you intentionally want to replace an existing image:

```bash
SPECTRE_FORCE=1 ./profiles/gnome/make-uefi-disk-image.sh
```

Or run the complete flow after the rootfs exists:

```bash
./profiles/gnome/build-uefi.sh ~/linux-7.1.8
```

## 7. Boot through UEFI firmware + GRUB

```bash
./profiles/gnome/run-qemu-uefi.sh
```

The launcher uses KVM when available, tries VirGL-capable Virtio graphics,
provides Virtio networking, USB keyboard/tablet, an entropy device when
available, and OVMF UEFI firmware.

The GRUB menu contains:

- the release name from `config/release.conf`
- text recovery
- safe graphics

## 8. Legacy direct-kernel development boot

The older root-only sparse image is still useful for fast debugging:

```bash
./profiles/gnome/make-disk-image.sh
./profiles/gnome/run-qemu.sh ~/linux-7.1.8/arch/x86/boot/bzImage
```

## Spectre desktop tools

Inside GNOME:

```bash
spectre-welcome
spectre-diagnostics
spectre-update --check
sudo spectre-update --apply
spectre-gnome-style --force
```

The boot health report is in the journal:

```bash
journalctl -b -u spectre-healthcheck.service
```

## If GNOME does not start

```bash
systemctl status gdm3
journalctl -b -p warning
journalctl -b -u gdm3
ls -l /dev/dri
loginctl seat-status seat0
spectre-diagnostics
```

## Architecture

```text
UEFI firmware / OVMF
        |
      GRUB
        |
Spectre 7.1.8 kernel + initramfs
        |
     systemd
        |
 D-Bus / logind
        |
NetworkManager    PipeWire
        |
Mesa + libinput
        |
Wayland / Mutter
        |
   GNOME Shell
        |
 Spectre Night UI
```

0.9 is still a development preview. The next large milestones are real-hardware
firmware coverage, a Calamares-quality guided installer, a signed Spectre
package overlay, rollback/recovery snapshots, Secure Boot signing and wider
hardware validation.


## Spectre desktop HUD

The real desktop now includes the system extension `spectre-hud@spectre.os`. It provides live right-side status cards without drawing fake application windows into the wallpaper. Toggle it from the top panel or Spectre Center.
