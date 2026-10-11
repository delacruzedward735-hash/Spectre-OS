from __future__ import annotations

import os
import shlex
import shutil
import subprocess
from typing import Callable, Iterable
from dataclasses import asdict

from .catalog import COLLECTIONS, POPULAR_TOOLS, collection_title, decorate_tool, meta_category
from .runtime import CONTAINER_NAME, IMAGE, ContainerRuntime, validate_package


def _load_bundled_snapshot() -> dict:
    """Release-verified, offline-browsable Kali package metadata, not installed tools."""
    import json
    from pathlib import Path
    path = Path(__file__).with_name("kali_catalog_snapshot.json")
    if not path.is_file():
        raise RuntimeError("Bundled Kali catalog is missing from this Spectre OS installation")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise RuntimeError("Bundled Kali catalog cannot be read") from exc
    rows = payload.get("tools")
    if not isinstance(rows, list) or len(rows) < 750:
        raise RuntimeError("Bundled Kali catalog invalid: fewer than 750 tool packages")
    packages = [x.get("package") for x in rows]
    if len(set(packages)) != len(packages):
        raise RuntimeError("Bundled Kali catalog contains duplicate packages")
    return payload


class ToolHubService:
    def __init__(self, runtime: ContainerRuntime):
        self.runtime = runtime
        self._tool_cache: list[dict] | None = None

    def status(self) -> dict:
        return {
            "runtime": self.runtime.name,
            "runtime_binary": self.runtime.binary,
            "container": CONTAINER_NAME,
            "image": IMAGE,
            "exists": self.runtime.exists(),
            "running": self.runtime.running(),
            "safe_mode": True,
        }

    def catalog(self) -> dict:
        """Return Kali collection/metapackage cards.

        Once the toolbox is running the list is discovered from the current Kali
        APT metadata, so new kali-tools-* metapackages appear automatically.
        Before initialization, the curated built-in set is a safe preview only.
        """
        installed: set[str] = set()
        running = self.runtime.exists() and self.runtime.running()
        if running:
            try:
                installed = {row["package"].split(":", 1)[0] for row in self.runtime.installed_packages()}
            except Exception:
                installed = set()
            discovered = self.runtime.discover_collections()
            cards: list[dict] = []
            for item in discovered:
                package = item["package"]
                known = next((x for x in COLLECTIONS if x.package == package), None)
                cards.append({
                    "package": package,
                    "title": collection_title(package),
                    "category": "Collections",
                    "description": item.get("description") or (known.description if known else "Current Kali tool collection."),
                    "weight": known.weight if known else ("huge" if package == "kali-linux-everything" else "standard"),
                    "warning": known.warning if known else ("Very large. Installs the complete Kali tool set." if package == "kali-linux-everything" else ""),
                    "installed": package in installed,
                })
            cards.sort(key=lambda row: (row["package"] != "kali-tools-top10", row["package"]))
            return {"categories": ["Collections"], "groups": cards, "discovered": True, "count": len(cards), "source": "kali-apt"}

        cards = []
        for item in COLLECTIONS:
            row = asdict(item)
            row["installed"] = False
            cards.append(row)
        return {"categories": ["Collections"], "groups": cards, "discovered": False, "count": len(cards), "source": "preview"}

    def tools(self, refresh: bool = False) -> dict:
        """Return the complete current Kali tool-package catalog.

        In a real initialized toolbox this is sourced exclusively from current
        Kali APT metadata.  No well-known package is injected into a discovered
        catalog if Kali no longer advertises it.  Before initialization a small
        preview is shown; mock mode is explicitly identified as a preview.
        """
        installed: set[str] = set()
        running = self.runtime.exists() and self.runtime.running()
        if running:
            try:
                installed = {row["package"].split(":", 1)[0] for row in self.runtime.installed_packages()}
            except Exception:
                installed = set()

        if not running and self.runtime.name != "mock":
            snapshot = _load_bundled_snapshot()
            rows = [dict(item, installed=False, available=True) for item in snapshot["tools"]]
            return {
                "tools": rows,
                "discovered": False,
                "count": len(rows),
                "source": "bundled-snapshot",
                "metapackage_count": snapshot.get("metapackage_count", 0),
                "snapshot_date": snapshot.get("release_date", "unknown"),
            }
        if refresh or self._tool_cache is None:
            discovered = self.runtime.discover_tools()
            rows: list[dict] = []
            for item in discovered:
                cats = [meta_category(meta) for meta in item.get("metapackages", [])]
                row = decorate_tool(
                    item["package"],
                    item.get("description", ""),
                    cats,
                    item["package"] in installed,
                )
                row["metapackages"] = list(item.get("metapackages", []))
                rows.append(row)
            rows.sort(key=lambda r: (not bool(r.get("popular")), r.get("title", "").casefold()))
            self._tool_cache = rows
        else:
            for row in self._tool_cache:
                row["installed"] = row["package"] in installed

        source = "mock-preview" if self.runtime.name == "mock" else "kali-apt"
        meta_count = 0
        try:
            meta_count = len(self.runtime.tool_metapackages())
        except Exception:
            pass
        return {
            "tools": list(self._tool_cache),
            "discovered": source == "kali-apt",
            "count": len(self._tool_cache),
            "source": source,
            "metapackage_count": meta_count,
        }

    def refresh_tools(self) -> dict:
        # A user-triggered refresh should mean current Kali Rolling metadata,
        # not merely a rebuild from an old apt index.  apt_update() happens
        # strictly inside the isolated Kali toolbox.
        self.runtime.apt_update()
        self._tool_cache = None
        return self.tools(refresh=True)

    def init(self) -> dict:
        self.runtime.ensure_running()
        self.runtime.apt_update()
        self._tool_cache = None
        return self.status()

    def install(self, package: str) -> dict:
        validate_package(package)
        result = self.runtime.install(package)
        return {"ok": result.ok, "package": package, "output": result.stdout + result.stderr}

    def install_many(self, packages: Iterable[str], progress: Callable[[dict], None] | None = None) -> dict:
        """Single-worker serialized APT queue. Never claim success without dpkg-query.

        APT update runs only once. Download/install percentages come from APT's
        Status-Fd; container pull and update are indeterminate steps.
        A failing package is reported, and later selected packages can continue.
        """
        unique: list[str] = []
        for package in packages:
            validate_package(package)
            if package not in unique:
                unique.append(package)
        if not unique:
            raise ValueError("No tool packages selected")
        if len(unique) > 25:
            raise ValueError("Maximum 25 tools per install batch to protect live storage")

        def emit(event: dict) -> None:
            if progress is not None:
                progress(dict(event))

        total = len(unique)
        emit({"stage": "prepare", "package": "", "index": 0, "total": total,
              "percent": None, "message": "Preparing isolated Kali container"})
        try:
            self.runtime.ensure_running()
            emit({"stage": "update", "package": "", "index": 0, "total": total,
                  "percent": None, "message": "Refreshing signed Kali APT package indexes"})
            self.runtime.apt_update()
        except Exception as exc:
            emit({"stage": "error", "package": "", "index": 0, "total": total,
                  "percent": None, "message": str(exc)})
            raise
        self._tool_cache = None
        successes: list[str] = []
        failures: dict[str, str] = {}
        for i, package in enumerate(unique, 1):
            emit({"stage": "prepare", "package": package, "index": i, "total": total,
                  "percent": None, "message": f"Checking {package}"})
            try:
                if self.runtime.is_installed(package):
                    successes.append(package)
                    emit({"stage": "already-installed", "package": package, "index": i,
                          "total": total, "percent": 100.0, "message": "Already installed"})
                    continue
                def per_package(event: dict) -> None:
                    emit(dict(event, package=package, index=i, total=total))
                self.runtime.install_stream(package, per_package)
                if not self.runtime.is_installed(package):
                    raise RuntimeError(f"dpkg verification failed for {package}")
                successes.append(package)
                emit({"stage": "complete", "package": package, "index": i,
                      "total": total, "percent": 100.0, "message": "Installed and verified"})
            except Exception as exc:
                failures[package] = str(exc)
                emit({"stage": "error", "package": package, "index": i,
                      "total": total, "percent": None, "message": str(exc)})
        return {"ok": not failures, "installed": successes, "failed": failures,
                "total": total, "completed": len(successes)}

    def remove(self, package: str) -> dict:
        validate_package(package)
        result = self.runtime.remove(package)
        return {"ok": result.ok, "package": package, "output": result.stdout + result.stderr}

    def search(self, query: str) -> dict:
        return {"query": query, "results": self.runtime.search(query)}

    def installed(self) -> dict:
        return {"packages": self.runtime.installed_packages()}

    def doctor(self) -> dict:
        problems: list[str] = []
        if self.runtime.name not in {"podman", "docker", "mock"}:
            problems.append("Unknown runtime")
        return {
            "ok": not problems,
            "runtime": self.runtime.name,
            "container": CONTAINER_NAME,
            "image": IMAGE,
            "problems": problems,
            "host": os.uname().sysname + " " + os.uname().release,
            "design": "Kali packages stay inside an isolated Kali container; no Kali APT repo is added to the host.",
        }

    def shell_command(self) -> str:
        return shlex.join(self.runtime.shell_argv())

    def open_shell(self) -> dict:
        argv = self.runtime.shell_argv()
        if self.runtime.name == "mock":
            return {"ok": True, "command": shlex.join(argv), "opened": False}
        terminal = self._terminal()
        if terminal is None:
            return {"ok": False, "command": shlex.join(argv), "opened": False, "error": "No supported terminal emulator found."}
        command = shlex.join(argv)
        base = terminal.rsplit("/", 1)[-1]
        if base in {"gnome-terminal", "kgx"}:
            launch = [terminal, "--", "bash", "-lc", command + "; exec bash"]
        elif base == "xfce4-terminal":
            launch = [terminal, "-x", "bash", "-lc", command + "; exec bash"]
        else:
            launch = [terminal, "-e", "bash", "-lc", command + "; exec bash"]
        subprocess.Popen(launch, start_new_session=True)
        return {"ok": True, "command": command, "opened": True}

    @staticmethod
    def _terminal() -> str | None:
        for name in ("gnome-terminal", "kgx", "konsole", "xfce4-terminal", "x-terminal-emulator"):
            path = shutil.which(name)
            if path:
                return path
        return None
