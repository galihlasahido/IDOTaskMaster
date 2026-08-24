#!/bin/bash
# Builds (Debug) and launches the app like a normal double-click — the
# fastest way to see the current state of the UI. For console/log output
# and breakpoints, use scripts/debug.sh instead.
#
# Usage: scripts/run.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source _common.sh

./build.sh Debug

APP_PATH="$(debug_app_path)"
echo "==> Launching $APP_PATH"
relaunch_app "$APP_PATH"
