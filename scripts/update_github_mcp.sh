#!/usr/bin/env bash
set -euo pipefail

VERSION="${GITHUB_MCP_VERSION:-1.12.1}"
INSTALL_DIR="${GITHUB_MCP_DIR:-/opt/serena-lsp-kit/github-mcp}"

[[ "$(id -u)" -eq 0 ]] || { echo "error: run as root" >&2; exit 1; }
for tool in curl tar sha256sum mktemp; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: missing $tool" >&2; exit 1; }
done

case "$(uname -m)" in
  x86_64|amd64) ARCH="x86_64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "error: unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

ASSET="github-mcp-server_Linux_${ARCH}.tar.gz"
CHECKSUMS="github-mcp-server_${VERSION}_checksums.txt"
BASE_URL="https://github.com/github/github-mcp-server/releases/download/v${VERSION}"
BINARY="$INSTALL_DIR/github-mcp-server"

if [[ -x "$BINARY" ]]; then
  current="$($BINARY --version 2>/dev/null || true)"
  if [[ "$current" == *"${VERSION}"* ]]; then
    echo "github_mcp_already=$BINARY"
    exit 0
  fi
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
curl -fsSL "$BASE_URL/$ASSET" -o "$work/$ASSET"
curl -fsSL "$BASE_URL/$CHECKSUMS" -o "$work/$CHECKSUMS"
(
  cd "$work"
  grep -E "[[:space:]]${ASSET}$" "$CHECKSUMS" | sha256sum -c -
)
mkdir -p "$INSTALL_DIR"
tar -xzf "$work/$ASSET" -C "$work"
install -m 0755 "$work/github-mcp-server" "$BINARY"
"$BINARY" --help >/dev/null
echo "github_mcp_installed=$BINARY"
