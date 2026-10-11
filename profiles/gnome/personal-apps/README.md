# Spectre Managed Application Framework

Spectre OS 1.0 Final ships **no CodeDev/personal applications in the base ISO**.

This directory contains only the dormant managed-application framework used for future optional additions:

- `registry.tsv` is empty by default.
- `managed_app.py` validates metadata.
- `validate-managed-apps.sh` validates registered applications.
- `install-managed-apps.sh` installs only explicitly registered applications.

The legacy SwiftShare/AppSweep source payloads and `install-personal-apps.sh` were retired from the Spectre 1.0 final core image.
