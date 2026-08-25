#!/bin/bash
# Compiles the IDOTaskMasterMCP command-line MCP server — a quick "does it
# still build" check, matching build.sh's own convention for the GUI app.
#
# Usage: scripts/build-mcp.sh [Debug|Release]
#   scripts/build-mcp.sh            # Debug (default)
#   scripts/build-mcp.sh Release
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source _common.sh
ensure_project

MCP_SCHEME="IDOTaskMasterMCP"
CONFIG="${1:-Debug}"

mcp_bin_path() { echo "$DERIVED_DATA_DIR/Build/Products/$1/$MCP_SCHEME"; }

echo "==> Building $MCP_SCHEME ($CONFIG)"
xcodebuild \
  -project "$PROJECT_FILE" \
  -scheme "$MCP_SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  build

echo "==> Build succeeded: $(mcp_bin_path "$CONFIG")"
