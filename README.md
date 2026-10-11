# Linux Spectre 1.0

**One desktop. Two worlds.**
*An independent Debian-based desktop for everyday computing with optional Kali Linux security tools.*

Linux Spectre is developed by **CodeDev by Edward**. The project began with the idea of keeping a comfortable daily Linux environment for browsing, studying, software development and general work while making ethical-hacking utilities available when they are needed.

The creator was inspired by **Kali Linux's** security-tool ecosystem and by the streamlined desktop customization associated with **Ghost Spectre Windows**. Linux Spectre is independent and not affiliated with either project.

## Features demonstrated in the tested installation

- Debian-based GNOME desktop with customized Spectre theming, wallpaper, login screen and monitoring widgets.
- Custom `7.1.8-spectre` kernel in the tested x86_64 VirtualBox installation.
- Native **Spectre ToolHub** based on GTK4/libadwaita with a **760-entry catalog**. *The entries are not 760 preinstalled programs.*
- On-demand **Kali Rolling** container managed with **rootless Podman**; selected tools installed through Kali APT repositories.
- Persistence of installed container packages across reboot (Nmap 7.99 verified).
- BIOS/UEFI bootable installation image; VirtualBox display userspace integration working in the tested environment.

## Architecture at a glance

```text
Linux Spectre desktop (Debian-based / GNOME)
    └─ Spectre ToolHub (GTK4/libadwaita)
         └─ Rootless Podman
              └─ Kali Rolling container
                   └─ Selected APT packages (e.g., Nmap)
```

Containers do not guarantee compatibility with all USB/Wi-Fi hardware or provide virtual-machine-level isolation. Tools must only be used on systems you own or are authorized to assess.

## Repository maturity

**Repository bootstrap / source-publication in progress.** This is not yet a complete source distribution: the authoritative OS build sources, customized kernel corresponding sources, and reproducible build inputs are awaiting a security and licensing audit. Do not represent this README or repository as containing the complete OS. The downloadable ISO is not yet published here.

For development transparency, see [Source publication status](docs/SOURCE_PUBLICATION.md), [architecture](docs/ARCHITECTURE.md), [license review](docs/LICENSING_STATUS.md), [security reporting](SECURITY.md) and [contributing](CONTRIBUTING.md).

## Links

- Product website: https://linux-spectre.myportfoliohub.online/
- Documentation: https://linux-spectre.myportfoliohub.online/docs/ (confirm live availability before use)

## Independent project and branding

Linux Spectre is not an official project of Debian, Kali Linux, GNOME, Oracle VirtualBox or Ghost Spectre. These marks belong to their respective owners. Official Linux Spectre name and logo rights are reserved by their respective creator/owner, subject to any third-party assets and applicable law. A source license has **not** been declared for original components pending ownership and license review.
