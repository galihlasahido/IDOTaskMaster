#!/bin/bash
# Compiles the app without launching it — a quick "does it still build" check.
#
# Usage: scripts/build.sh [Debug|Release]
#   scripts/build.sh            # Debug (default)
#   scripts/build.sh Release
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source _common.sh
ensure_project

CONFIG="${1:-Debug}"

echo "==> Building $APP_NAME ($CONFIG)"
xcodebuild \
  -project "$PROJECT_FILE" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  build

if [ "$CONFIG" = "Release" ]; then
  APP_PATH="$(release_app_path)"
else
  APP_PATH="$(debug_app_path)"
fi

# See sign_adhoc's own doc comment: the linker's own ad-hoc signature
# from the build above binds the wrong identifier, which silently
# breaks notifications (and possibly other identity-checked APIs) —
# fully re-sign so this build behaves like a real one, not just a
# "does it compile" check.
echo "==> Re-signing (ad-hoc)"
sign_adhoc "$APP_PATH"

echo "==> Build succeeded: $APP_PATH"
