#!/bin/bash
# Builds an optimized Release build and copies it to dist/IDOTaskMaster.app —
# the input scripts/dmg.sh and scripts/pkg.sh package for distribution.
#
# Unsigned/ad-hoc by default (fine for running on this Mac). To produce a
# properly signed build (required before notarizing or sharing with
# another Mac under Gatekeeper), pass your Apple Developer Team ID:
#
#   DEVELOPMENT_TEAM=ABCDE12345 scripts/release.sh
#
# Usage: scripts/release.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source _common.sh
ensure_project

SIGN_ARGS=(CODE_SIGNING_ALLOWED=NO)
if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
  echo "==> Signing with Development Team $DEVELOPMENT_TEAM"
  SIGN_ARGS=(CODE_SIGN_STYLE=Automatic "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
else
  echo "==> No DEVELOPMENT_TEAM set — building ad-hoc/unsigned."
  echo "    That's fine to run on this Mac. For a properly signed build,"
  echo "    re-run as: DEVELOPMENT_TEAM=<your Apple Developer Team ID> $0"
fi

echo "==> Building $APP_NAME (Release)"
xcodebuild \
  -project "$PROJECT_FILE" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  "${SIGN_ARGS[@]}" \
  build

# Only for the ad-hoc path: a real DEVELOPMENT_TEAM build above already
# gets a proper Developer ID signature from Xcode itself. See
# sign_adhoc's own doc comment for why the ad-hoc path otherwise ships
# with a signature that silently breaks notifications.
if [ -z "${DEVELOPMENT_TEAM:-}" ]; then
  echo "==> Re-signing (ad-hoc)"
  sign_adhoc "$(release_app_path)"
fi

mkdir -p "$DIST_DIR"
rm -rf "$DIST_DIR/$APP_NAME.app"
cp -R "$(release_app_path)" "$DIST_DIR/$APP_NAME.app"

echo "==> Release build ready: $DIST_DIR/$APP_NAME.app"
