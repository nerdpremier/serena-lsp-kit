#!/usr/bin/env bash
set -euo pipefail

NODE_VERSION="${NODE_VERSION:-24.21.0}"
PLAYWRIGHT_MCP_VERSION="${PLAYWRIGHT_MCP_VERSION:-0.0.80}"
BASE_DIR="${MCP_KIT_BASE:-/opt/serena-lsp-kit}"
NODE_DIR="$BASE_DIR/node"
PLAYWRIGHT_DIR="$BASE_DIR/playwright"
BROWSERS_DIR="$BASE_DIR/ms-playwright"

[[ "$(id -u)" -eq 0 ]] || { echo "error: run as root" >&2; exit 1; }
for tool in curl tar sha256sum mktemp; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: missing $tool" >&2; exit 1; }
done

case "$(uname -m)" in
  x86_64|amd64) ARCH="x64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "error: unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

ASSET="node-v${NODE_VERSION}-linux-${ARCH}.tar.xz"
BASE_URL="https://nodejs.org/dist/v${NODE_VERSION}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [[ ! -x "$NODE_DIR/bin/node" ]] || [[ "$("$NODE_DIR/bin/node" --version 2>/dev/null || true)" != "v${NODE_VERSION}" ]]; then
  curl -fsSL "$BASE_URL/$ASSET" -o "$work/$ASSET"
  curl -fsSL "$BASE_URL/SHASUMS256.txt" -o "$work/SHASUMS256.txt"
  (
    cd "$work"
    grep -E "[[:space:]]${ASSET}$" SHASUMS256.txt | sha256sum -c -
  )
  rm -rf "$NODE_DIR"
  mkdir -p "$NODE_DIR"
  tar -xJf "$work/$ASSET" -C "$NODE_DIR" --strip-components=1
fi

mkdir -p "$PLAYWRIGHT_DIR" "$BROWSERS_DIR"
PATH="$NODE_DIR/bin:$PATH" "$NODE_DIR/bin/npm" install --prefix "$PLAYWRIGHT_DIR" --omit=dev --no-audit --no-fund \
  "@playwright/mcp@${PLAYWRIGHT_MCP_VERSION}" >/dev/null

PLAYWRIGHT_CLI="$PLAYWRIGHT_DIR/node_modules/@playwright/mcp/cli.js"
[[ -f "$PLAYWRIGHT_CLI" ]] || { echo "error: Playwright MCP CLI not installed" >&2; exit 1; }
PLAYWRIGHT_BROWSERS_PATH="$BROWSERS_DIR" \
  "$NODE_DIR/bin/node" "$PLAYWRIGHT_DIR/node_modules/playwright/cli.js" install chromium >/dev/null

"$NODE_DIR/bin/node" "$PLAYWRIGHT_CLI" --version >/dev/null
printf 'node_bin=%s\nplaywright_cli=%s\nplaywright_browsers=%s\n' \
  "$NODE_DIR/bin/node" "$PLAYWRIGHT_CLI" "$BROWSERS_DIR"
