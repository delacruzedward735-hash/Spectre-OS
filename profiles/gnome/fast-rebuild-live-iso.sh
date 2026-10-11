#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
printf '[Spectre] Safe rebuild mode: the live filesystem will be regenerated.\n'
printf '[Spectre] Stale SquashFS reuse is disabled so branding, cleanup and app-boundary changes cannot be skipped.\n'
exec "$ROOT/profiles/gnome/build-live-iso.sh" "$@"
