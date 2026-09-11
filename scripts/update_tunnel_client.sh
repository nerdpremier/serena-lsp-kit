#!/usr/bin/env bash
set -euo pipefail

VERSION="${TUNNEL_CLIENT_VERSION:-0.0.14}"
TUNNEL_DIR="${TUNNEL_DIR:-/root/mcp-workspace/tunnel-client}"

if [[ -n "${TUNNEL_CLIENT_ARCH:-}" ]]; then
  ARCH="$TUNNEL_CLIENT_ARCH"
else
  case "$(uname -m)" in
    x86_64|amd64) ARCH="linux-amd64" ;;
    aarch64|arm64) ARCH="linux-arm64" ;;
    *) echo "error: unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac
fi

ASSET="tunnel-client-v${VERSION}-${ARCH}.zip"
CHECKSUMS="SHA256SUMS.txt"
BASE_URL="https://github.com/openai/tunnel-client/releases/download/v${VERSION}"

[[ "$(id -u)" -eq 0 ]] || { echo "error: run as root" >&2; exit 1; }
for tool in curl unzip sha256sum mktemp; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: missing $tool" >&2; exit 1; }
done

if [[ -x "$TUNNEL_DIR/tunnel-client" ]]; then
  current="$("${TUNNEL_DIR}/tunnel-client" --version 2>/dev/null || true)"
  if [[ "$current" == "${VERSION}"* ]]; then
    echo "tunnel_client_already=${current}"
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

mkdir -p "$work/unpack"
unzip -q "$work/$ASSET" -d "$work/unpack"
[[ -x "$work/unpack/tunnel-client" ]] || { echo "error: archive has no tunnel-client" >&2; exit 1; }

mkdir -p "$TUNNEL_DIR"
if [[ -e "$TUNNEL_DIR/tunnel-client" ]]; then
  backup="$TUNNEL_DIR/backup-$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$backup"
  for f in tunnel-client cloudflared cloudflared-manifest.json LICENSE NOTICE; do
    [[ -e "$TUNNEL_DIR/$f" ]] && cp -a "$TUNNEL_DIR/$f" "$backup/"
  done
fi
for f in "$work/unpack"/*; do
  cp -a "$f" "$TUNNEL_DIR/"
done
chmod 0755 "$TUNNEL_DIR/tunnel-client"

installed="$("${TUNNEL_DIR}/tunnel-client" --version)"
[[ "$installed" == "${VERSION}"* ]] || { echo "error: installed unexpected version: $installed" >&2; exit 1; }
echo "tunnel_client_installed=$installed"
