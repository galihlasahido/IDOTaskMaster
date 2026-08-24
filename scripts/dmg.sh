#!/bin/bash
# Packages the Release build into a distributable .dmg (a Finder window
# with the app and an Applications shortcut to drag it into, the standard
# way Mac apps are shared outside the App Store).
#
# Runs scripts/release.sh first if dist/IDOTaskMaster.app doesn't exist yet.
#
# Usage: scripts/dmg.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source _common.sh

APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
if [ ! -d "$APP_BUNDLE" ]; then
  echo "==> No Release build found, building one first..."
  ./release.sh
fi

DMG_PATH="$DIST_DIR/${APP_NAME}-${MARKETING_VERSION}.dmg"
STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT

cp -R "$APP_BUNDLE" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"
echo "==> Creating $DMG_PATH"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -fs HFS+ \
  -ov -format UDZO \
  "$DMG_PATH" \
  >/dev/null

echo "==> DMG ready: $DMG_PATH"
