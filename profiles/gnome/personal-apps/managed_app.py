#!/usr/bin/env python3
"""Shared parser/validator for Spectre managed application metadata."""
from __future__ import annotations
from pathlib import Path
import re

ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
RUNTIMES = {"python-venv", "python-system", "native-binary"}
STATES = {"enabled", "disabled"}
KEYS = {
    "APP_ID", "APP_NAME", "APP_VERSION", "APP_STATE", "APP_RUNTIME", "APP_ENTRY",
    "APP_COMMAND", "APP_LAUNCHER", "APP_ICON", "APP_ICON_FILE", "APP_COMMENT",
    "APP_CATEGORIES", "APP_KEYWORDS", "APP_TERMINAL", "APP_REQUIREMENTS",
}
REQUIRED = {
    "APP_ID", "APP_NAME", "APP_VERSION", "APP_STATE", "APP_RUNTIME", "APP_ENTRY",
    "APP_COMMAND", "APP_LAUNCHER", "APP_ICON", "APP_COMMENT", "APP_CATEGORIES",
    "APP_TERMINAL",
}


def _clean_value(raw: str) -> str:
    raw = raw.strip()
    if len(raw) >= 2 and raw[0] == raw[-1] == '"':
        raw = raw[1:-1]
    if any(ord(ch) < 32 and ch not in "\t" for ch in raw):
        raise ValueError("control character in metadata")
    if "\t" in raw or "\n" in raw or "\r" in raw:
        raise ValueError("tabs/newlines are not allowed in metadata values")
    return raw


def parse_conf(path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ValueError(f"{path}:{number}: expected KEY=VALUE")
        key, value = line.split("=", 1)
        key = key.strip()
        if key not in KEYS:
            raise ValueError(f"{path}:{number}: unsupported key {key}")
        if key in data:
            raise ValueError(f"{path}:{number}: duplicate key {key}")
        data[key] = _clean_value(value)
    missing = sorted(REQUIRED - data.keys())
    if missing:
        raise ValueError(f"{path}: missing keys: {', '.join(missing)}")
    for key in KEYS:
        data.setdefault(key, "")
    validate_conf(data, path)
    return data


def validate_conf(d: dict[str, str], path: Path | None = None) -> None:
    label = str(path) if path else "app.conf"
    app_id = d["APP_ID"]
    if not ID_RE.fullmatch(app_id):
        raise ValueError(f"{label}: invalid APP_ID {app_id!r}")
    if d["APP_RUNTIME"] not in RUNTIMES:
        raise ValueError(f"{label}: unsupported runtime {d['APP_RUNTIME']}")
    if d["APP_STATE"] not in STATES:
        raise ValueError(f"{label}: invalid state {d['APP_STATE']}")
    if d["APP_TERMINAL"] not in {"true", "false"}:
        raise ValueError(f"{label}: APP_TERMINAL must be true or false")
    if not d["APP_VERSION"] or any(ch.isspace() for ch in d["APP_VERSION"]):
        raise ValueError(f"{label}: invalid version")
    entry = Path(d["APP_ENTRY"])
    if entry.is_absolute() or ".." in entry.parts or not d["APP_ENTRY"]:
        raise ValueError(f"{label}: APP_ENTRY must be a safe relative path")
    if d["APP_COMMAND"] != f"/usr/bin/{app_id}":
        raise ValueError(f"{label}: APP_COMMAND must be /usr/bin/{app_id}")
    if d["APP_LAUNCHER"] != f"{app_id}.desktop":
        raise ValueError(f"{label}: APP_LAUNCHER must be {app_id}.desktop")
    if not d["APP_CATEGORIES"].endswith(";"):
        raise ValueError(f"{label}: APP_CATEGORIES must end with ';'")
    if d["APP_KEYWORDS"] and not d["APP_KEYWORDS"].endswith(";"):
        raise ValueError(f"{label}: APP_KEYWORDS must end with ';' when set")
    if d["APP_ICON_FILE"] and Path(d["APP_ICON_FILE"]).name != d["APP_ICON_FILE"]:
        raise ValueError(f"{label}: APP_ICON_FILE must be a basename")
    if d["APP_ICON_FILE"] and Path(d["APP_ICON_FILE"]).suffix.lower() not in {".png", ".svg"}:
        raise ValueError(f"{label}: APP_ICON_FILE must be PNG or SVG")
    if d["APP_REQUIREMENTS"] and Path(d["APP_REQUIREMENTS"]).name != d["APP_REQUIREMENTS"]:
        raise ValueError(f"{label}: APP_REQUIREMENTS must be a basename")
    if d["APP_REQUIREMENTS"] and d["APP_RUNTIME"] != "python-venv":
        raise ValueError(f"{label}: requirements are only allowed for python-venv")


def parse_registry(path: Path) -> list[tuple[str, str, str, str, str]]:
    rows: list[tuple[str, str, str, str, str]] = []
    seen: set[str] = set()
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not raw.strip() or raw.startswith("#"):
            continue
        cols = raw.split("\t")
        if len(cols) != 5:
            raise ValueError(f"{path}:{number}: expected 5 tab-separated columns")
        app_id, version, state, runtime, app_dir = cols
        if not ID_RE.fullmatch(app_id) or app_dir != app_id:
            raise ValueError(f"{path}:{number}: invalid id/app_dir")
        if app_id in seen:
            raise ValueError(f"{path}:{number}: duplicate id {app_id}")
        if state not in STATES or runtime not in RUNTIMES:
            raise ValueError(f"{path}:{number}: invalid state/runtime")
        if not version or any(ch.isspace() for ch in version):
            raise ValueError(f"{path}:{number}: invalid version")
        seen.add(app_id)
        rows.append((app_id, version, state, runtime, app_dir))
    return rows
