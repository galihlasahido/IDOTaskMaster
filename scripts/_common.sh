#!/bin/bash
# Shared config/helpers sourced by every script in this directory.
# Not meant to be run directly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PROJECT_FILE="$PROJECT_DIR/IDOTaskMaster.xcodeproj"
SCHEME="IDOTaskMaster"
APP_NAME="IDOTaskMaster"
BUNDLE_ID="com.idotaskmaster.mac"
# Keep this in sync with project.yml's MARKETING_VERSION.
MARKETING_VERSION="0.1.0"

# Project-local build output (gitignored) rather than Xcode's global
# DerivedData — keeps the .app at a path every script can predict.
DERIVED_DATA_DIR="$PROJECT_DIR/.build"
DIST_DIR="$PROJECT_DIR/dist"

debug_app_path() { echo "$DERIVED_DATA_DIR/Build/Products/Debug/$APP_NAME.app"; }
release_app_path() { echo "$DERIVED_DATA_DIR/Build/Products/Release/$APP_NAME.app"; }

# Regenerates IDOTaskMaster.xcodeproj from project.yml if it's missing
# (e.g. a fresh clone before the .xcodeproj is committed/regenerated).
ensure_project() {
  if [ -d "$PROJECT_FILE" ]; then
    return
  fi
  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: $PROJECT_FILE not found and xcodegen isn't installed." >&2
    echo "       Install it with: brew install xcodegen" >&2
    exit 1
  fi
  echo "==> Xcode project missing, generating it with xcodegen..."
  (cd "$PROJECT_DIR" && xcodegen generate)
}

# Kills any running copy of the app so a relaunch shows fresh code
# instead of an old process still holding the window open.
relaunch_app() {
  local app_path="$1"
  pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null 2>&1 || true
  sleep 0.5
  open "$app_path"
}
