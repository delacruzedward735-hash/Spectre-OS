# Linux Spectre 1.0 — partial source branch

This branch contains only the reviewed **GNOME source profile and Spectre ToolHub**. It is **not the complete Linux Spectre operating system** and **cannot reproduce the verified RC8.6 ISO** from a public checkout.

The historical build requires private RC1 recovery image, optimized kernel modules, and an Oracle VirtualBox Guest Additions archive intentionally excluded here.

The working ISO identifies Linux kernel `7.1.8-spectre`, but corresponding full kernel source, patch lineage, and a clean source-based build have not been verified. The 13,227-line kernel configuration recovered from the ISO is kept separate pending provenance review.

Source publication still requires ownership and licensing review for the original code, imported code, artwork, fonts, icons, and dependencies. **No new license is granted by this staging operation.** A public GitHub branch is visible to everyone, even before merging a pull request.

Until these issues are resolved, do not call this a complete open-source distribution or publish the qualified ISO as publicly redistributable.
