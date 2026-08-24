#!/bin/bash
# Packages the Release build into a distributable .pkg installer (double-
# click, click through Install, the app lands in /Applications).
#
# Runs scripts/release.sh first if dist/IDOTaskMaster.app doesn't exist yet.
# Unsigned by default; pass a signing identity from your keychain to sign
# the installer package (needed before notarizing):
#
#   INSTALLER_SIGN_IDENTITY="Developer ID Installer: Your Name (TEAMID)" scripts/pkg.sh
#
# Usage: scripts/pkg.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source _common.sh

APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
if [ ! -d "$APP_BUNDLE" ]; then
  echo "==> No Release build found, building one first..."
  ./release.sh
fi

PKG_PATH="$DIST_DIR/${APP_NAME}-${MARKETING_VERSION}.pkg"
PKG_ROOT="$(mktemp -d)"
trap 'rm -rf "$PKG_ROOT"' EXIT

mkdir -p "$PKG_ROOT/Applications"
cp -R "$APP_BUNDLE" "$PKG_ROOT/Applications/"

SIGN_ARGS=()
if [ -n "${INSTALLER_SIGN_IDENTITY:-}" ]; then
  echo "==> Signing installer with $INSTALLER_SIGN_IDENTITY"
  SIGN_ARGS=(--sign "$INSTALLER_SIGN_IDENTITY")
else
  echo "==> No INSTALLER_SIGN_IDENTITY set — building an unsigned .pkg."
fi

rm -f "$PKG_PATH"
echo "==> Creating $PKG_PATH"
pkgbuild \
  --root "$PKG_ROOT" \
  --identifier "$BUNDLE_ID" \
  --version "$MARKETING_VERSION" \
  --install-location / \
  "${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"}" \
  "$PKG_PATH"

echo "==> PKG ready: $PKG_PATH"
