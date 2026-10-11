# Spectre OS Installer RC2

This is the release-candidate **erase-one-disk** installation path for Spectre OS.
It is deliberately narrower than a mature distribution installer: manual
partitioning, dual-boot/alongside installation, disk encryption, RAID and LVM are
not enabled in RC1.

## Safety contract

- Runs only from Spectre live media because a live SquashFS must be present.
- Excludes the disk containing the live installer media.
- Requires a writable target of at least 32 GiB.
- Revalidates disk size and serial immediately before destructive operations.
- Requires the operator to type `ERASE /dev/<selected-disk>` exactly.
- Creates one GPT that supports both UEFI and legacy BIOS boot.
- Uses an isolated `/run` in the target chroot; live-session mounts are never
  copied into the installed initramfs.
- Removes Debian live-boot/live-config and all Spectre installer privileges from
  the installed operating system before first boot.
- A successful result requires bootloader, fstab, user authentication hash,
  Spectre identity and clean-unmount verification.

## Qualification order

1. Rebuild and verify the ISO.
2. Reset the disposable QEMU disk with `reset-qemu-install-test.sh`.
3. Boot the live ISO with `run-qemu-iso.sh` and erase only the shown virtual disk.
4. Power off, then boot only the installed disk with `run-qemu-installed.sh`.
5. Log in and run `spectre-installed-health`.
6. Reset the disposable disk and repeat with `run-qemu-iso-bios.sh`, then boot it with `run-qemu-installed-bios.sh`.
7. Reboot/login repeatedly before any physical-machine erase test.

## Installer RC4 — premium experience pass

RC4 keeps the RC3 privileged disk backend and safety gates intact while refining the normal-user GTK4/Libadwaita frontend:

- 1120×760 premium guided installer window with richer Spectre visual hierarchy.
- Spectre wallpaper + dedicated installer artwork on the Welcome experience.
- Storage assessment card that distinguishes an empty disk, an existing-partition disk, and a Windows-compatible EFI/NTFS layout without weakening backend confirmation.
- Keyboard test field and password-strength feedback.
- Summary boot-mode and final disk revalidation explanation.
- Rotating install-time feature cards using local Spectre artwork only; the installer remains fully usable offline.
- Creator signature: **CodeDev by Edward**, created by **John Edward Q. Dela Cruz**, with the official portfolio link `https://myportfoliohub.online`.
- Creator/project content is intentionally limited to Welcome, install-time slides, About and Finish so disk/account steps stay trustworthy and focused.

The RC3 alongside-Windows implementation remains conservative: it only uses already-unallocated space and still requires privileged verification of Microsoft Boot Manager before writing.


## RC4.1 live-session policy
The installation USB auto-logs into a passwordless disposable `spectre` account and provides passwordless sudo only in the live environment. The installer removes that policy from the target and creates the permanent owner account using the password entered in the Account step.
