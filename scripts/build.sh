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
  echo "==> Build succeeded: $(release_app_path)"
else
  echo "==> Build succeeded: $(debug_app_path)"
fi
