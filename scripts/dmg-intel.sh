#!/bin/bash
# Packages an Intel-only (x86_64) build into its own distributable .dmg —
# a smaller download for Intel Mac users than the universal
# scripts/dmg.sh one, which embeds both architectures in one binary.
#
# `lipo -thin` extracts just the x86_64 slice from the existing universal
# Release build (scripts/release.sh) rather than doing a second full
# compile — same source, same compiler output, just one architecture's
# slice — then re-signs it, since thinning a signed binary invalidates
# its signature.
#
# Runs scripts/release.sh first if dist/IDOTaskMaster.app doesn't exist
# yet.
#
# Usage: scripts/dmg-intel.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source _common.sh

APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
if [ ! -d "$APP_BUNDLE" ]; then
  echo "==> No Release build found, building one first..."
  ./release.sh
fi

BIN_PATH="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
if ! lipo -info "$BIN_PATH" 2>/dev/null | grep -q x86_64; then
  echo "error: $BIN_PATH has no x86_64 slice to thin — is it a universal build?" >&2
  exit 1
fi

DMG_PATH="$DIST_DIR/${APP_NAME}-${MARKETING_VERSION}-intel.dmg"
STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT

INTEL_APP="$STAGING_DIR/$APP_NAME.app"
cp -R "$APP_BUNDLE" "$INTEL_APP"

echo "==> Thinning to x86_64"
lipo -thin x86_64 "$BIN_PATH" -output "$INTEL_APP/Contents/MacOS/$APP_NAME"

# Thinning invalidates the universal build's ad-hoc signature (the
# CodeDirectory hash covers the fat binary's exact bytes) — re-sign the
# thinned copy the same ad-hoc way scripts/release.sh's own default
# (no DEVELOPMENT_TEAM) does.
echo "==> Re-signing (ad-hoc)"
codesign --force --deep --sign - "$INTEL_APP"

ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"
echo "==> Creating $DMG_PATH"
hdiutil create \
  -volname "$APP_NAME (Intel)" \
  -srcfolder "$STAGING_DIR" \
  -fs HFS+ \
  -ov -format UDZO \
  "$DMG_PATH" \
  >/dev/null

echo "==> Intel DMG ready: $DMG_PATH"
