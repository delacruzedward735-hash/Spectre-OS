# Architecture — Linux Spectre 1.0

## Host

- Debian-based userland and GNOME desktop.
- Custom kernel identified as `7.1.8-spectre` in the qualified VirtualBox guest.
- Spectre appearance, login screen, monitoring widgets, and custom ToolHub UI.
- BIOS/UEFI installer used to create a persistent ext4 installation on the tested VM.

## ToolHub container workflow

Spectre ToolHub runs as a native GTK4/libadwaita application, and provides an offline-browsable 760-entry catalog. Tool selection and installation are distinct: packages are not present until chosen and installed. ToolHub starts a rootless Podman Kali Rolling container and installs selected packages through the container's APT repositories. The current GUI supports limited-size batch installation (up to 25 selected catalog entries per batch in reviewed source), with progress and per-package feedback.

On a fresh guest, rootless Podman needs valid subordinate UID and GID mappings. `spectre-rootless-podman-subids.service` was confirmed successful in the tested environment. The named container `spectre-kali-toolbox` preserved Nmap 7.99 across reboot.

## Display

The qualified VirtualBox installation used `spectre-vbox-display.service`, `VBoxDRMClient` and `VBoxService`, without enabling the failing vendor kernel-module build service. This integration is conditional on Oracle/VirtualBox virtualization; it is not a declaration of broad physical GPU compatibility.

## Build status

The tested 1.8 GB ISO had checksum `a49d7602a772c2db1dfb72411e47574ec908c5337d05131cb10433119f689d76`. Its historical build used a recovery ISO and read-only ext4 baseline from the maintainer's Zorin host. These inputs and license provenance are **not yet available in this repository**, and a public-source clean build has not been demonstrated.

## Security model

Rootless Podman reduces the container daemon privilege footprint and isolates package dependencies. It is **not** a security boundary equivalent to a hypervisor and not a guarantee that every tool is safe. Maintain up-to-date packages and only test authorized targets.
