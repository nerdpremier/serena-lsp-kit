#!/usr/bin/env bash
set -euo pipefail

PLAYWRIGHT_MCP_VERSION="${PLAYWRIGHT_MCP_VERSION:-0.0.80}"
BASE_DIR="${MCP_KIT_BASE:-/opt/serena-lsp-kit}"
NODE_DIR="$BASE_DIR/node"
PLAYWRIGHT_DIR="$BASE_DIR/playwright"
BROWSERS_DIR="$BASE_DIR/ms-playwright"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

[[ "$(id -u)" -eq 0 ]] || { echo "error: run as root" >&2; exit 1; }
MCP_KIT_BASE="$BASE_DIR" bash "$SCRIPT_DIR/update_node.sh" >/dev/null

mkdir -p "$PLAYWRIGHT_DIR" "$BROWSERS_DIR"
NPM_CLI="$NODE_DIR/lib/node_modules/npm/bin/npm-cli.js"
[[ -f "$NPM_CLI" ]] || { echo "error: managed npm CLI not found: $NPM_CLI" >&2; exit 1; }
"$NODE_DIR/bin/node" "$NPM_CLI" install --loglevel=error --prefix "$PLAYWRIGHT_DIR" --omit=dev --no-audit --no-fund \
  "@playwright/mcp@${PLAYWRIGHT_MCP_VERSION}" >/dev/null

PLAYWRIGHT_CLI="$PLAYWRIGHT_DIR/node_modules/@playwright/mcp/cli.js"
[[ -f "$PLAYWRIGHT_CLI" ]] || { echo "error: Playwright MCP CLI not installed" >&2; exit 1; }
PLAYWRIGHT_BROWSERS_PATH="$BROWSERS_DIR" \
  "$NODE_DIR/bin/node" "$PLAYWRIGHT_DIR/node_modules/playwright/cli.js" install chromium >/dev/null

"$NODE_DIR/bin/node" "$PLAYWRIGHT_CLI" --version >/dev/null
printf 'node_bin=%s\nplaywright_cli=%s\nplaywright_browsers=%s\n' \
  "$NODE_DIR/bin/node" "$PLAYWRIGHT_CLI" "$BROWSERS_DIR"
