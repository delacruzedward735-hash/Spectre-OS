#!/usr/bin/python3
"""Spectre OS installed-system subordinate ID provisioning for rootless Podman.

Invoked as root by a one-shot systemd service before graphical login.
Changes ONLY /etc/subuid and /etc/subgid through Debian usermod.
Never runs Podman as root or resets container storage.
"""
from __future__ import annotations

import datetime
import fcntl
import grp
import os
from pathlib import Path
import pwd
import shutil
import time
import subprocess
import sys

COUNT = 65536
START = 100000
LAST = 600100000  # exclusive
SUBFILES = ("/etc/subuid", "/etc/subgid")

class UnsafeState(Exception):
    pass


def parse_subids(contents: str, label: str) -> list[tuple[str, int, int]]:
    rows = []
    for n, raw in enumerate(contents.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        vals = line.split(":")
        if len(vals) != 3 or not vals[0] or vals[0] != vals[0].strip():
            raise UnsafeState(f"Malformed {label} line {n}; not changing mappings")
        try:
            start, count = int(vals[1]), int(vals[2])
        except ValueError as exc:
            raise UnsafeState(f"Invalid numeric values in {label} line {n}") from exc
        if start < 0 or count <= 0 or start + count > 2**32:
            raise UnsafeState(f"Out-of-bounds {label} line {n}")
        rows.append((vals[0], start, count))
    return rows


def check_overlaps(rows: list[tuple[str, int, int]], label: str) -> None:
    ordered = sorted(rows, key=lambda row: row[1])
    for a, b in zip(ordered, ordered[1:]):
        if a[1] + a[2] > b[1]:
            raise UnsafeState(f"Overlapping ranges in {label}: {a[0]} and {b[0]}; manual investigation required")


def sufficient(rows: list[tuple[str, int, int]], username: str, uid: int) -> bool:
    return any(owner in (username, str(uid)) and length >= COUNT
               for owner, _, length in rows)


def next_available(rows: list[tuple[str, int, int]], reserved: set[int]) -> tuple[int, int]:
    intervals = sorted((base, base + length) for _, base, length in rows)
    intervals += [(value, value + 1) for value in reserved if START <= value < LAST]
    intervals.sort()
    candidate = START
    for low, high in intervals:
        if candidate + COUNT <= low:
            break
        if candidate < high and candidate + COUNT > low:
            candidate = high
    if candidate + COUNT > LAST:
        raise UnsafeState("No unused block of 65536 subordinate IDs remains")
    return candidate, candidate + COUNT - 1


def configured_local_files() -> None:
    nss = Path("/etc/nsswitch.conf")
    if not nss.exists():
        return
    for line in nss.read_text().splitlines():
        value = line.strip()
        if value.startswith("subid:") and "files" not in value.split(":", 1)[1].split():
            raise UnsafeState("Subordinate identities use non-file NSS provider; refusing local edits")


def is_live_boot() -> bool:
    try:
        fs = subprocess.check_output(
            ["findmnt", "-n", "-o", "FSTYPE", "/"], text=True, timeout=10
        ).strip()
    except (subprocess.SubprocessError, FileNotFoundError) as exc:
        raise UnsafeState(f"Cannot determine root filesystem: {exc}") from exc
    return fs in {"overlay", "aufs", "squashfs"}


def backup_subids() -> Path:
    folder = Path("/var/backups/spectre-rootless-podman") / datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    folder.mkdir(parents=True, mode=0o700, exist_ok=False)
    for name in SUBFILES:
        path = Path(name)
        if path.exists():
            shutil.copy2(path, folder / path.name)
    return folder


def regular_users() -> list[tuple[str, int]]:
    return sorted((entry.pw_name, entry.pw_uid) for entry in pwd.getpwall()
                  if 1000 <= entry.pw_uid < 60000 and entry.pw_name != "nobody")


def add_subordinate_range(kind: str, user: str, uid: int,
                          reserved: set[int]) -> None:
    """Retry ONLY genuine account-database lock contention.

    Recheck fresh mappings on every attempt, so another account writer cannot
    make a previously chosen range stale.  Never delete a shadow lockfile.
    """
    if kind not in {"uid", "gid"}:
        raise UnsafeState("Invalid subordinate ID kind")
    path = Path("/etc/subuid" if kind == "uid" else "/etc/subgid")
    opt = "--add-subuids" if kind == "uid" else "--add-subgids"
    for attempt in range(1, 6):
        rows = parse_subids(path.read_text(), str(path))
        check_overlaps(rows, str(path))
        if sufficient(rows, user, uid):
            return
        first, last = next_available(rows, reserved)
        cmd = ["usermod", opt, f"{first}-{last}", user]
        try:
            result = subprocess.run(cmd, capture_output=True, text=True,
                                    timeout=45, check=False)
        except subprocess.TimeoutExpired as exc:
            # The timeout does not prove a usermod transaction was rolled
            # back; fail closed instead of blindly starting another one.
            raise UnsafeState(f"usermod timeout for {user}; inspect account state") from exc
        if result.returncode == 0:
            # Even an apparent success must be checked against fresh files.
            continue
        msg = (result.stderr or result.stdout or "").strip()
        low = msg.lower()
        if "cannot lock /etc/" not in low and "resource temporarily unavailable" not in low:
            raise UnsafeState(f"usermod {kind} failed for {user}: {msg}")
        if attempt == 5:
            raise UnsafeState(f"Account database remained locked after five attempts: {msg}")
        print(f"[RETRY] Account DB busy ({kind} for {user}), attempt {attempt}/5", flush=True)
        time.sleep(min(2 * attempt, 8))
    # The only successful exit from the loop is when 'sufficient' detects
    # the mapping.  Re-evaluate one final time for clarity.
    if not sufficient(parse_subids(path.read_text(), str(path)), user, uid):
        raise UnsafeState(f"No subordinate {kind} mapping found for {user}")


def ensure_ranges() -> None:
    if os.geteuid() != 0:
        raise UnsafeState("This service must be run by systemd as root")
    if is_live_boot():
        print("[SKIP] Live environment; installed-system provisioning only", flush=True)
        return
    configured_local_files()
    for executable in ("usermod", "newuidmap", "newgidmap"):
        if not shutil.which(executable):
            raise UnsafeState(f"Required package or utility missing: {executable}")
    for name in SUBFILES:
        path = Path(name)
        if path.is_symlink():
            raise UnsafeState(f"Refusing symlink: {name}")
        if not path.exists():
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
            os.close(fd)

    lock_path = "/run/lock/spectre-rootless-podman-subids.lock"
    with open(lock_path, "a+", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        uids = parse_subids(Path(SUBFILES[0]).read_text(), SUBFILES[0])
        gids = parse_subids(Path(SUBFILES[1]).read_text(), SUBFILES[1])
        check_overlaps(uids, SUBFILES[0])
        check_overlaps(gids, SUBFILES[1])
        reserved_uid = {u.pw_uid for u in pwd.getpwall()}
        reserved_gid = {g.gr_gid for g in grp.getgrall()}
        missing = [(user, uid) for user, uid in regular_users()
                   if not (sufficient(uids, user, uid) and sufficient(gids, user, uid))]
        if not missing:
            print("[PASS] All regular accounts already have subordinate UID/GID mappings", flush=True)
            return
        backup = backup_subids()
        print(f"[BACKUP] Existing subordinate ID files: {backup}", flush=True)
        for user, uid in missing:
            # Refresh after usermod in case its allocator modifies both files.
            uids = parse_subids(Path(SUBFILES[0]).read_text(), SUBFILES[0])
            gids = parse_subids(Path(SUBFILES[1]).read_text(), SUBFILES[1])
            check_overlaps(uids, SUBFILES[0])
            check_overlaps(gids, SUBFILES[1])
            if not sufficient(uids, user, uid):
                add_subordinate_range("uid", user, uid, reserved_uid)
                print(f"[PASS] {user}: subordinate UID range assigned", flush=True)
            if not sufficient(gids, user, uid):
                add_subordinate_range("gid", user, uid, reserved_gid)
                print(f"[PASS] {user}: subordinate GID range assigned", flush=True)
            uids = parse_subids(Path(SUBFILES[0]).read_text(), SUBFILES[0])
            gids = parse_subids(Path(SUBFILES[1]).read_text(), SUBFILES[1])
            if not (sufficient(uids, user, uid) and sufficient(gids, user, uid)):
                raise UnsafeState(f"Mappings not sufficient after provisioning for {user}")
        check_overlaps(uids, SUBFILES[0])
        check_overlaps(gids, SUBFILES[1])
        print("[PASS] Installed OS rootless Podman subordinate mapping provisioning completed", flush=True)

if __name__ == "__main__":
    try:
        ensure_ranges()
    except (UnsafeState, OSError, subprocess.SubprocessError) as exc:
        print(f"[FAIL] Spectre subordinate ID provisioning: {exc}", file=sys.stderr, flush=True)
        sys.exit(1)
