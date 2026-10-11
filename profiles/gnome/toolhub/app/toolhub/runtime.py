from __future__ import annotations

import os
import re
import shlex
import shutil
import subprocess
import threading
from collections import deque
from dataclasses import dataclass
from typing import Callable
from pathlib import Path
from typing import Sequence

PACKAGE_RE = re.compile(r"^[a-z0-9][a-z0-9+.-]{0,127}$")
QUERY_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 _+./:-]{0,79}$")
CONTAINER_NAME = "spectre-kali-toolbox"
IMAGE = "docker.io/kalilinux/kali-rolling:latest"

# Official Kali tool-bearing metapackages outside the kali-tools-* namespace.
# Seeding these alongside every current kali-tools-* metapackage prevents the
# catalog from missing tools that Kali places only in the core/headless/default/
# large/everything selections.  The system/desktop metapackages themselves are
# still filtered out and never shown as individual tools.
TOOL_SET_METAPACKAGES: tuple[str, ...] = (
    "kali-linux-core",
    "kali-linux-headless",
    "kali-linux-default",
    "kali-linux-large",
    "kali-tools-top10",
    "kali-linux-everything",
)

# Direct dependencies of kali-linux-everything that are clearly OS plumbing or
# appearance/development support rather than security applications.  Specific
# kali-tools-* collections remain authoritative for actual security tools.
NON_TOOL_PACKAGES: frozenset[str] = frozenset({
    "android-sdk",
    "kali-community-wallpapers",
    "kali-wallpapers-all",
    "xclip",
    "vim",
    "vim-nox",
    "vim-tiny",
})


class RuntimeErrorBase(RuntimeError):
    pass


class RuntimeUnavailable(RuntimeErrorBase):
    pass


class InvalidPackage(ValueError):
    pass


@dataclass
class CmdResult:
    argv: list[str]
    returncode: int
    stdout: str = ""
    stderr: str = ""

    @property
    def ok(self) -> bool:
        return self.returncode == 0


def parse_tool_dependencies(output: str, metapackages: list[str]) -> dict[str, set[str]]:
    """Parse apt-cache depends output into real package -> source metapackages."""
    allowed = set(metapackages)
    current = ""
    package_metas: dict[str, set[str]] = {}
    dep_re = re.compile(r"^[ |]*(?:Pre)?Depends:\s+(.+?)\s*$")
    for raw in output.splitlines():
        if raw and not raw[0].isspace() and not raw.startswith("|"):
            header = raw.strip().split(":", 1)[0]
            current = header if header in allowed else ""
            continue
        if not current:
            continue
        match = dep_re.match(raw)
        if not match:
            continue
        dep = match.group(1).strip()
        if dep.startswith("<") or dep.endswith(">"):
            continue
        dep = dep.split()[0].split(":", 1)[0]
        if dep.startswith("kali-tools-") or dep.startswith("kali-linux-") or dep.startswith("kali-system-") or dep.startswith("kali-desktop-"):
            continue
        if not PACKAGE_RE.fullmatch(dep):
            continue
        package_metas.setdefault(dep, set()).add(current)
    return package_metas


def parse_package_descriptions(output: str) -> dict[str, str]:
    descriptions: dict[str, str] = {}
    current = ""
    for line in output.splitlines():
        if line.startswith("Package: "):
            current = line.split(":", 1)[1].strip().split(":", 1)[0]
        elif current and (line.startswith("Description-en: ") or line.startswith("Description: ")):
            descriptions.setdefault(current, line.split(":", 1)[1].strip())
    return descriptions



def parse_apt_status(line: str) -> dict | None:
    """Parse documented APT Status-Fd records; no guessed percentages."""
    parts = line.strip().split(":", 3)
    if len(parts) != 4 or parts[0] not in {"dlstatus", "pmstatus", "pmerror"}:
        return None
    kind, subject, raw_percent, description = parts
    try:
        percent = float(raw_percent)
    except ValueError:
        return None
    if not 0 <= percent <= 100:
        return None
    return {
        "stage": "download" if kind == "dlstatus" else "install" if kind == "pmstatus" else "error",
        "percent": percent,
        "message": description.strip()[:300],
        "subject": subject,
    }


class ContainerRuntime:
    def __init__(self, binary: str, dry_run: bool = False):
        self.binary = binary
        self.dry_run = dry_run

    @property
    def name(self) -> str:
        return Path(self.binary).name

    def run(self, args: Sequence[str], *, check: bool = True, timeout: int | None = None) -> CmdResult:
        argv = [self.binary, *args]
        if self.dry_run:
            return CmdResult(argv, 0, stdout="DRY-RUN: " + shlex.join(argv) + "\n")
        proc = subprocess.run(argv, text=True, capture_output=True, timeout=timeout)
        result = CmdResult(argv, proc.returncode, proc.stdout, proc.stderr)
        if check and proc.returncode != 0:
            msg = proc.stderr.strip() or proc.stdout.strip() or f"command failed: {shlex.join(argv)}"
            raise RuntimeErrorBase(msg)
        return result

    def exists(self) -> bool:
        if self.dry_run:
            return False
        result = self.run(["container", "inspect", CONTAINER_NAME], check=False, timeout=10)
        if self.name == "podman" and result.returncode != 0:
            # Older/newer Podman both accept `inspect`; keep the fallback simple.
            result = self.run(["inspect", CONTAINER_NAME], check=False, timeout=10)
        return result.returncode == 0

    def running(self) -> bool:
        if self.dry_run:
            return False
        fmt = "{{.State.Running}}"
        result = self.run(["inspect", "--format", fmt, CONTAINER_NAME], check=False, timeout=10)
        return result.returncode == 0 and result.stdout.strip().lower() == "true"

    def pull(self) -> CmdResult:
        return self.run(["pull", IMAGE], timeout=1800)

    def create(self) -> CmdResult:
        # Default is intentionally unprivileged. It is suitable for package
        # management, CLI tools and lab workflows, but not direct Wi-Fi/USB
        # hardware access. Hardware mode belongs in a later, explicit feature.
        args = [
            "run", "-d", "--name", CONTAINER_NAME,
            "--hostname", "spectre-kali",
            "--security-opt", "no-new-privileges",
            IMAGE, "sleep", "infinity",
        ]
        return self.run(args, timeout=120)

    def start(self) -> CmdResult:
        return self.run(["start", CONTAINER_NAME], timeout=60)

    def ensure_running(self) -> None:
        if not self.exists():
            self.pull()
            self.create()
        elif not self.running():
            self.start()

    def exec(self, command: Sequence[str], *, check: bool = True, timeout: int | None = None) -> CmdResult:
        self.ensure_running()
        return self.run(["exec", "-u", "0", CONTAINER_NAME, *command], check=check, timeout=timeout)

    def apt_update(self) -> CmdResult:
        return self.exec(["apt-get", "update"], timeout=1800)

    def install(self, package: str) -> CmdResult:
        validate_package(package)
        self.apt_update()
        return self.exec([
            "env", "DEBIAN_FRONTEND=noninteractive",
            "apt-get", "install", "-y", package,
        ], timeout=7200)

    def install_stream(self, package: str, progress: Callable[[dict], None] | None = None) -> CmdResult:
        """Install one package with APT's *real* progress; apt_update is caller-owned.

        APT::Status-Fd writes dlstatus/pmstatus on stdout alongside normal logs.
        The subprocess runs in the existing unprivileged Podman/Docker container.
        """
        validate_package(package)
        self.ensure_running()
        argv = [self.binary, "exec", "-u", "0", CONTAINER_NAME,
                "env", "DEBIAN_FRONTEND=noninteractive", "LC_ALL=C",
                "apt-get", "-o", "APT::Status-Fd=1", "-o", "Dpkg::Use-Pty=0",
                "install", "-y", package]
        if self.dry_run:
            return CmdResult(argv, 0, "DRY-RUN: " + shlex.join(argv) + "\n")
        proc = subprocess.Popen(argv, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True,
                                bufsize=1, errors="replace")
        tail: deque[str] = deque(maxlen=500)
        expired = threading.Event()
        def stop_on_timeout():
            if proc.poll() is None:
                expired.set()
                proc.kill()
        timer = threading.Timer(7200, stop_on_timeout)
        timer.daemon = True
        timer.start()
        try:
            assert proc.stdout is not None
            for line in proc.stdout:
                clean = line.rstrip("\r\n")
                tail.append(clean)
                if progress is not None:
                    parsed = parse_apt_status(clean)
                    if parsed:
                        progress(parsed)
                    else:
                        # Bounded plain logs for diagnostics, not a fake percentage.
                        progress({"stage": "log", "percent": None, "message": clean[:400]})
            code = proc.wait()
        finally:
            timer.cancel()
            if proc.poll() is None:
                proc.kill()
                proc.wait()
        output = "\n".join(tail) + "\n"
        if expired.is_set():
            raise RuntimeErrorBase(f"APT timed out installing {package}: {output[-1500:]}")
        if code != 0:
            raise RuntimeErrorBase(f"APT install failed for {package} (exit {code}): {output[-2400:]}")
        return CmdResult(argv, code, output)

    def remove(self, package: str) -> CmdResult:
        validate_package(package)
        return self.exec([
            "env", "DEBIAN_FRONTEND=noninteractive",
            "apt-get", "remove", "-y", package,
        ], timeout=3600)

    def is_installed(self, package: str) -> bool:
        validate_package(package)
        result = self.exec(["dpkg-query", "-W", "-f=${Status}", package], check=False, timeout=30)
        return result.returncode == 0 and "install ok installed" in result.stdout

    def installed_packages(self, limit: int = 5000) -> list[dict]:
        result = self.exec(["dpkg-query", "-W", "-f=${binary:Package}\t${Version}\\n"], timeout=60)
        rows: list[dict] = []
        for line in result.stdout.splitlines()[:limit]:
            if "\t" in line:
                package, version = line.split("\t", 1)
                rows.append({"package": package, "version": version})
        return rows

    def search(self, query: str, limit: int = 80) -> list[dict]:
        query = validate_query(query)
        result = self.exec(["apt-cache", "search", "--names-only", query], timeout=60)
        rows: list[dict] = []
        for line in result.stdout.splitlines():
            if " - " not in line:
                continue
            package, description = line.split(" - ", 1)
            package = package.strip()
            if not PACKAGE_RE.match(package):
                continue
            rows.append({"package": package, "description": description.strip()})
            if len(rows) >= limit:
                break
        return rows

    def tool_metapackages(self) -> list[str]:
        """Return Kali's current tool metapackages from APT metadata."""
        self.ensure_running()
        result = self.exec(["apt-cache", "search", "--names-only", "^kali-tools-"], timeout=60)
        metas: list[str] = []
        for line in result.stdout.splitlines():
            if " - " not in line:
                continue
            package = line.split(" - ", 1)[0].strip()
            if package.startswith("kali-tools-") and PACKAGE_RE.fullmatch(package):
                metas.append(package)
        return sorted(set(metas))

    def collection_metapackages(self) -> list[str]:
        """Return every current Kali tool collection relevant to ToolHub.

        This is deliberately runtime-driven.  New kali-tools-* packages that
        appear in Kali Rolling are picked up automatically without a ToolHub
        release.
        """
        dynamic = self.tool_metapackages()
        candidates = [*TOOL_SET_METAPACKAGES, *dynamic]
        result = self.exec(["apt-cache", "show", "--no-all-versions", *candidates], check=False, timeout=120)
        available = set(parse_package_descriptions(result.stdout))
        if not available:
            # apt-cache show can be terse on an unrefreshed index; keep the
            # dynamically discovered kali-tools-* list and let the caller
            # decide which static tool-set packages are available.
            available.update(dynamic)
        return sorted({pkg for pkg in candidates if pkg in available or pkg in dynamic})

    def discover_collections(self) -> list[dict]:
        """Discover current Kali tool metapackages and descriptions."""
        packages = self.collection_metapackages()
        descriptions = self._package_descriptions(packages)
        return [
            {"package": package, "description": descriptions.get(package, "")}
            for package in packages
        ]

    def discover_tools(self, limit: int | None = None) -> list[dict]:
        """Discover the complete current Kali tool-package catalog.

        ToolHub expands every current ``kali-tools-*`` package plus Kali's
        official core/headless/default/large/top10/everything tool selections.
        Only *immediate* dependencies are treated as catalog entries so library
        dependencies are not mistaken for user-facing tools.  Duplicate tools
        are merged while retaining every source metapackage/category.

        ``limit`` exists only for callers/tests that intentionally request a
        truncated view.  The normal GUI/CLI passes no limit, so there is no
        arbitrary catalog ceiling.
        """
        metas = self.tool_metapackages()
        if not metas:
            return []

        seeds = list(dict.fromkeys([*TOOL_SET_METAPACKAGES, *metas]))
        result = self.exec(["apt-cache", "depends", *seeds], timeout=240)
        package_metas = parse_tool_dependencies(result.stdout, seeds)

        # Remove explicitly non-tool support packages while preserving real
        # applications that Kali exposes only through kali-linux-* selections.
        for package in list(package_metas):
            if package in NON_TOOL_PACKAGES:
                del package_metas[package]

        packages = sorted(package_metas)
        if limit is not None:
            packages = packages[: max(0, limit)]

        descriptions = self._package_descriptions(packages)
        rows: list[dict] = []
        for package in packages:
            rows.append({
                "package": package,
                "description": descriptions.get(package, ""),
                "metapackages": sorted(package_metas[package]),
            })
        return rows

    def _package_descriptions(self, packages: list[str]) -> dict[str, str]:
        descriptions: dict[str, str] = {}
        # Keep argv sizes modest across container runtimes.
        for start in range(0, len(packages), 120):
            chunk = packages[start:start + 120]
            if not chunk:
                continue
            result = self.exec(["apt-cache", "show", "--no-all-versions", *chunk], check=False, timeout=120)
            if result.returncode != 0:
                result = self.exec(["apt-cache", "show", *chunk], check=False, timeout=120)
            descriptions.update({
                package: description
                for package, description in parse_package_descriptions(result.stdout).items()
                if package not in descriptions
            })
        return descriptions

    def shell_argv(self) -> list[str]:
        self.ensure_running()
        return [self.binary, "exec", "-it", CONTAINER_NAME, "/bin/bash"]

    def stop(self) -> CmdResult:
        return self.run(["stop", CONTAINER_NAME], check=False, timeout=60)


class MockRuntime(ContainerRuntime):
    def __init__(self):
        super().__init__("mock-runtime", dry_run=True)
        self._exists = False
        self._running = False
        self._installed: set[str] = set()

    @property
    def name(self) -> str:
        return "mock"

    def exists(self) -> bool:
        return self._exists

    def running(self) -> bool:
        return self._running

    def pull(self) -> CmdResult:
        return CmdResult(["mock", "pull", IMAGE], 0, "mock pull ok\n")

    def create(self) -> CmdResult:
        self._exists = True
        self._running = True
        return CmdResult(["mock", "create", CONTAINER_NAME], 0, "mock create ok\n")

    def start(self) -> CmdResult:
        self._exists = True
        self._running = True
        return CmdResult(["mock", "start", CONTAINER_NAME], 0, "mock start ok\n")

    def apt_update(self) -> CmdResult:
        self.ensure_running()
        return CmdResult(["mock", "apt-get", "update"], 0, "mock apt update ok\n")

    def install(self, package: str) -> CmdResult:
        validate_package(package)
        self.ensure_running()
        self._installed.add(package)
        return CmdResult(["mock", "install", package], 0, f"installed {package}\n")

    def install_stream(self, package: str, progress: Callable[[dict], None] | None = None) -> CmdResult:
        if progress:
            progress({"stage": "log", "percent": None, "message": f"Mock installing {package}"})
        return self.install(package)

    def remove(self, package: str) -> CmdResult:
        validate_package(package)
        self._installed.discard(package)
        return CmdResult(["mock", "remove", package], 0, f"removed {package}\n")

    def is_installed(self, package: str) -> bool:
        validate_package(package)
        return package in self._installed

    def installed_packages(self, limit: int = 5000) -> list[dict]:
        return [{"package": p, "version": "mock-1.0"} for p in sorted(self._installed)[:limit]]

    def search(self, query: str, limit: int = 80) -> list[dict]:
        validate_query(query)
        sample = [
            {"package": "nmap", "description": "network exploration tool and security scanner"},
            {"package": "wireshark", "description": "network traffic analyzer"},
            {"package": "gobuster", "description": "directory and DNS busting tool"},
            {"package": "kali-tools-web", "description": "Kali web assessment metapackage"},
        ]
        q = query.casefold()
        return [r for r in sample if q in (r["package"] + " " + r["description"]).casefold()][:limit]

    def tool_metapackages(self) -> list[str]:
        self.ensure_running()
        return [
            "kali-tools-information-gathering",
            "kali-tools-vulnerability",
            "kali-tools-web",
            "kali-tools-database",
            "kali-tools-passwords",
            "kali-tools-wireless",
            "kali-tools-reverse-engineering",
            "kali-tools-exploitation",
            "kali-tools-social-engineering",
            "kali-tools-sniffing-spoofing",
            "kali-tools-post-exploitation",
            "kali-tools-forensics",
            "kali-tools-reporting",
            "kali-tools-identify",
            "kali-tools-protect",
            "kali-tools-detect",
            "kali-tools-respond",
            "kali-tools-recover",
            "kali-tools-802-11",
            "kali-tools-bluetooth",
            "kali-tools-crypto-stego",
            "kali-tools-fuzzing",
            "kali-tools-gpu",
            "kali-tools-hardware",
            "kali-tools-rfid",
            "kali-tools-sdr",
            "kali-tools-voip",
            "kali-tools-windows-resources",
        ]

    def collection_metapackages(self) -> list[str]:
        self.ensure_running()
        return sorted(set([*TOOL_SET_METAPACKAGES, *self.tool_metapackages()]))

    def discover_collections(self) -> list[dict]:
        return [
            {"package": package, "description": f"Mock preview of {package}"}
            for package in self.collection_metapackages()
        ]

    def discover_tools(self, limit: int | None = None) -> list[dict]:
        self.ensure_running()
        sample = [
            ("nmap", "Network exploration tool and security scanner", ["kali-tools-information-gathering", "kali-tools-vulnerability"]),
            ("wireshark", "Network traffic analyzer", ["kali-tools-sniffing-spoofing"]),
            ("metasploit-framework", "Penetration testing framework", ["kali-tools-exploitation", "kali-tools-reverse-engineering"]),
            ("burpsuite", "Web application security testing platform", ["kali-tools-web"]),
            ("sqlmap", "Automatic SQL injection tool", ["kali-tools-database", "kali-tools-web"]),
            ("hydra", "Parallel network login auditor", ["kali-tools-passwords"]),
            ("john", "Password hash auditing tool", ["kali-tools-passwords"]),
            ("hashcat", "Password recovery utility", ["kali-tools-passwords"]),
            ("responder", "LLMNR and NBT-NS analysis utility", ["kali-tools-sniffing-spoofing"]),
            ("netexec", "Network service assessment utility", ["kali-tools-post-exploitation"]),
            ("nikto", "Web server scanner", ["kali-tools-vulnerability", "kali-tools-web"]),
            ("gobuster", "Directory and DNS busting tool", ["kali-tools-web"]),
            ("wfuzz", "Web application fuzzer", ["kali-tools-fuzzing", "kali-tools-web"]),
            ("zaproxy", "Web application testing proxy", ["kali-tools-web"]),
            ("ghidra", "Software reverse engineering framework", ["kali-tools-reverse-engineering"]),
            ("radare2", "Reverse engineering framework", ["kali-tools-reverse-engineering"]),
            ("binwalk", "Firmware analysis tool", ["kali-tools-hardware"]),
            ("autopsy", "Digital forensics platform", ["kali-tools-forensics"]),
            ("tcpdump", "Command-line packet analyzer", ["kali-tools-sniffing-spoofing"]),
            ("aircrack-ng", "Wireless network assessment suite", ["kali-tools-hardware"]),
        ]
        rows = [
            {"package": p, "description": d, "metapackages": m}
            for p, d, m in sample
        ]
        return rows if limit is None else rows[: max(0, limit)]

    def shell_argv(self) -> list[str]:
        self.ensure_running()
        return ["echo", "mock Kali shell"]

    def stop(self) -> CmdResult:
        self._running = False
        return CmdResult(["mock", "stop"], 0, "mock stopped\n")


def validate_package(package: str) -> str:
    if not isinstance(package, str) or not PACKAGE_RE.fullmatch(package):
        raise InvalidPackage("Invalid package name. Only Debian package-name characters are allowed.")
    return package


def validate_query(query: str) -> str:
    query = query.strip()
    if len(query) < 1 or not QUERY_RE.fullmatch(query):
        raise ValueError("Search query contains unsupported characters or is empty.")
    return query


def detect_runtime(preferred: str | None = None, *, dry_run: bool = False) -> ContainerRuntime:
    override = (preferred or os.getenv("SPECTRE_TOOLHUB_RUNTIME") or "").strip().lower()
    if override == "mock":
        return MockRuntime()
    choices = [override] if override in {"podman", "docker"} else ["podman", "docker"]
    for name in choices:
        binary = shutil.which(name)
        if binary:
            return ContainerRuntime(binary, dry_run=dry_run)
    if dry_run:
        return ContainerRuntime(override or "podman", dry_run=True)
    raise RuntimeUnavailable(
        "No supported container runtime found. Install Podman (recommended) or Docker, then retry."
    )
