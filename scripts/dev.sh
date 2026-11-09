#!/usr/bin/env bash
# Rebuild a debug bundle and relaunch it with the Manage Workspaces window open.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
app="$("$root/scripts/bundle.sh" debug | tail -1)"
"$(dirname "$0")/stop.sh"
open "$app" --args --manage
