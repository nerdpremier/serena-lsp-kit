#!/usr/bin/env bash
set -euo pipefail

NODE_VERSION="${NODE_VERSION:-24.21.0}"
BASE_DIR="${MCP_KIT_BASE:-/opt/serena-lsp-kit}"
NODE_DIR="$BASE_DIR/node"

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

NPM_CLI="$NODE_DIR/lib/node_modules/npm/bin/npm-cli.js"
[[ -f "$NPM_CLI" ]] || { echo "error: managed npm CLI not found: $NPM_CLI" >&2; exit 1; }
"$NODE_DIR/bin/node" --version >/dev/null
"$NODE_DIR/bin/node" "$NPM_CLI" --version >/dev/null
printf 'node_bin=%s\n' "$NODE_DIR/bin/node"
