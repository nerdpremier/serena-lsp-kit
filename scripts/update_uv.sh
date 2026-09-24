#!/usr/bin/env bash
set -euo pipefail

UV_VERSION="${UV_VERSION:-0.12.18}"
BASE_DIR="${MCP_KIT_BASE:-/opt/serena-lsp-kit}"
UV_DIR="${UV_DIR:-$BASE_DIR/uv}"
UV_BIN="$UV_DIR/bin/uv"
UVX_BIN="$UV_DIR/bin/uvx"

[[ "$(id -u)" -eq 0 ]] || { echo "error: run as root" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "error: missing required command: python3" >&2; exit 1; }
[[ "$UV_DIR" = /* && "$UV_DIR" != "/" ]] || { echo "error: UV_DIR must be an absolute non-root path" >&2; exit 1; }

expected="uv $UV_VERSION"
installed="$("$UV_BIN" --version 2>/dev/null || true)"
if [[ -x "$UV_BIN" && -x "$UVX_BIN" ]] && [[ "$installed" == "$expected"* ]]; then
  echo "uv_already=$installed"
  echo "uv_bin=$UV_BIN"
  echo "uvx_bin=$UVX_BIN"
  exit 0
fi

rm -rf "$UV_DIR"
python3 -m venv "$UV_DIR"
"$UV_DIR/bin/python" -m pip install --disable-pip-version-check --upgrade pip >/dev/null
"$UV_DIR/bin/python" -m pip install --disable-pip-version-check "uv==$UV_VERSION" >/dev/null

[[ -x "$UV_BIN" ]] || { echo "error: uv executable not found: $UV_BIN" >&2; exit 1; }
[[ -x "$UVX_BIN" ]] || { echo "error: uvx executable not found: $UVX_BIN" >&2; exit 1; }
installed="$("$UV_BIN" --version 2>/dev/null || true)"
[[ "$installed" == "$expected"* ]] || {
  echo "error: unexpected uv version: $installed" >&2
  exit 1
}
"$UVX_BIN" --version >/dev/null

echo "uv_installed=$expected"
echo "uv_bin=$UV_BIN"
echo "uvx_bin=$UVX_BIN"
