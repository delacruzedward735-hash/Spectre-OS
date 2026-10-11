#!/usr/bin/env bash
set -Eeuo pipefail
APP=/usr/lib/spectre-toolhub
[[ -d "$APP/toolhub" ]] || { echo '[Spectre ToolHub] application payload missing.' >&2; exit 1; }
cd "$APP"
exec /usr/bin/python3 -m toolhub "$@"
