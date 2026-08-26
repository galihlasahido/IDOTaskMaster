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
MARKETING_VERSION="0.4.1"

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

# Re-signs an already-built .app with a full ad-hoc signature that
# properly seals Info.plist and its resources.
#
# A plain `CODE_SIGNING_ALLOWED=NO` xcodebuild still produces *some*
# signature on Apple Silicon (arm64 binaries must have one to run at
# all) — but it's the linker's own bare-minimum ad-hoc signature, which
# only covers the executable and, critically, binds the *executable's
# name* as the signed identifier instead of the real CFBundleIdentifier
# (`com.idotaskmaster.mac`). That mismatch silently breaks anything that
# checks the app's signed identity — most notably
# `UNUserNotificationCenter`: `requestAuthorization` throws
# `UNErrorDomain Code=1` ("Notifications are not allowed for this
# application") forever, with no permission prompt ever shown, because
# the system can't verify which app is actually asking. This full
# `--deep --sign -` re-sign fixes that by sealing the whole bundle
# (Info.plist included) under its real identifier.
sign_adhoc() {
  local app_path="$1"
  codesign --force --deep --sign - "$app_path"
}
