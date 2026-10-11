from __future__ import annotations

import argparse
import json
import sys

from . import __version__
from .catalog import COLLECTIONS
from .native_gui import gui_dependency_status, run_native_gui
from .runtime import RuntimeUnavailable, detect_runtime
from .service import ToolHubService
from .webapp import serve


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="spectre-toolhub", description="Isolated Kali tool store for Linux desktops")
    p.add_argument("--runtime", choices=["podman", "docker", "mock"], help="container runtime override")
    p.add_argument("--dry-run", action="store_true", help="show/test commands without changing the host")
    p.add_argument("--version", action="version", version=__version__)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("doctor", help="host/runtime diagnostic")
    sub.add_parser("status", help="show toolbox status")
    sub.add_parser("init", help="pull/create/start the isolated Kali toolbox")
    sub.add_parser("catalog", help="list optional Kali collections")
    t = sub.add_parser("tools", help="list actual Kali tool packages discovered from kali-tools-* metadata"); t.add_argument("--refresh", action="store_true")
    i = sub.add_parser("install", help="install a Kali package/metapackage inside the toolbox"); i.add_argument("package")
    r = sub.add_parser("remove", help="remove a package/metapackage from the toolbox"); r.add_argument("package")
    s = sub.add_parser("search", help="search apt-cache inside the Kali toolbox"); s.add_argument("query")
    sub.add_parser("installed", help="list packages installed in the toolbox")
    sub.add_parser("shell", help="print the command used to enter the Kali toolbox")
    g = sub.add_parser("gui", help="launch the native GTK4/libadwaita desktop UI"); g.add_argument("--check", action="store_true", help="check native GUI dependencies and exit")
    w = sub.add_parser("web", help="launch legacy localhost web UI"); w.add_argument("--port", type=int, default=8787); w.add_argument("--no-browser", action="store_true")
    return p


def emit(data):
    print(json.dumps(data, indent=2, sort_keys=True))


def main(argv=None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.cmd == "gui":
            if args.check:
                status = gui_dependency_status(); emit(status); return 0 if status["ok"] else 4
            return run_native_gui(args.runtime, dry_run=args.dry_run)

        runtime = detect_runtime(args.runtime, dry_run=args.dry_run)
        svc = ToolHubService(runtime)
        if args.cmd == "doctor": emit(svc.doctor())
        elif args.cmd == "status": emit(svc.status())
        elif args.cmd == "init": emit(svc.init())
        elif args.cmd == "catalog":
            for g in COLLECTIONS: print(f"{g.package:34} {g.category:18} {g.title}")
        elif args.cmd == "tools":
            result = svc.tools(refresh=args.refresh)
            for row in result["tools"]:
                marker = "*" if row.get("installed") else " "
                print(f"{marker} {row['package']:28} {row.get('category', ''):24} {row.get('title', '')}")
        elif args.cmd == "install": emit(svc.install(args.package))
        elif args.cmd == "remove": emit(svc.remove(args.package))
        elif args.cmd == "search": emit(svc.search(args.query))
        elif args.cmd == "installed": emit(svc.installed())
        elif args.cmd == "shell": print(svc.shell_command())
        elif args.cmd == "web": serve(svc, port=args.port, open_browser=not args.no_browser)
        return 0
    except RuntimeUnavailable as exc:
        print(f"ERROR: {exc}", file=sys.stderr); return 3
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr); return 2


if __name__ == "__main__":
    raise SystemExit(main())
