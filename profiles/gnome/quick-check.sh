#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
printf '[Spectre] Fast source validation — no ISO rebuild\n'
"$ROOT/profiles/gnome/validate-project.sh"
printf '\n[ok] Fast source validation passed.\n'
printf 'Runtime source: %s\n' "$("$ROOT/profiles/gnome/runtime-source-hash.sh")"
