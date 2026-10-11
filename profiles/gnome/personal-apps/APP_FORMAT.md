# Spectre 1.0 managed application format

Managed CodeDev applications live under:

```
profiles/gnome/personal-apps/apps/<app-id>/
├── app.conf
├── payload/
├── requirements.lock      # python-venv only, optional when no third-party deps
└── icon.png|icon.svg      # optional
```

`registry.tsv` is the authoritative ordered enable/disable registry.

Supported runtime types:

- `python-venv` — isolated per-app virtualenv under `/opt/codedev/apps/<id>/.venv`.
- `python-system` — uses Debian's `/usr/bin/python3`; no pip mutation of system Python.
- `native-binary` — executes an already-built Linux binary shipped in `payload/`.

Applications are installed as ordinary user applications. The managed app layer does not
create autostart entries, system services, sudoers entries, Polkit rules, firewall rules,
or other OS-wide privilege hooks.
