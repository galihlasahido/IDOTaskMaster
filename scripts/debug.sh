#!/bin/bash
# Builds (Debug) and runs the app under lldb, so print()/NSLog() output
# streams to this terminal and you can Ctrl+C to break in and inspect
# state. For just seeing the UI with no debugger attached, use
# scripts/run.sh instead — it launches faster and behaves like a normal
# double-click.
#
# Usage: scripts/debug.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source _common.sh

./build.sh Debug

APP_PATH="$(debug_app_path)"
BIN_PATH="$APP_PATH/Contents/MacOS/$APP_NAME"

pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null 2>&1 || true
sleep 0.5

echo "==> Launching $APP_NAME under lldb — Ctrl+C to break in, 'c' to continue, 'q' to quit"
lldb -o run "$BIN_PATH"
