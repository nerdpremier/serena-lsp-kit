#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_PATH=""
TUNNEL_ID="${SERENA_TUNNEL_ID:-}"
SERENA_HEALTH_PORT="${SERENA_HEALTH_PORT:-18090}"
SERENA_SERVICE="${SERENA_SERVICE:-serena-tunnel.service}"
TUNNEL_DIR="${TUNNEL_DIR:-/root/mcp-workspace/tunnel-client}"
TUNNEL_PROFILE="${TUNNEL_PROFILE:-/root/.config/tunnel-client/chatgpt-mcp.yaml}"
TUNNEL_ENV="${TUNNEL_ENV:-/root/.config/tunnel-client/serena-tunnel.env}"
SYSTEMD_UNIT="${SYSTEMD_UNIT:-/etc/systemd/system/serena-tunnel.service}"
SERENA_CONFIG="${SERENA_CONFIG:-/root/.serena/serena_config.yml}"
SERENA_VENV="${SERENA_VENV:-/opt/serena-lsp-kit/serena-venv}"

usage() {
  cat <<'EOF'
Usage: sudo ./bootstrap.sh /absolute/path/to/project [--tunnel-id tunnel_...]

Fresh-machine setup for Serena LSP Kit. It will:
  1. install Serena 1.7.0 into an isolated venv when needed;
  2. install tunnel-client 0.0.14;
  3. ask for tunnel_id and CONTROL_PLANE_API_KEY (key input is hidden);
  4. create the tunnel profile and systemd service;
  5. apply LSP-only hardening, enable the service, and health-check it.

You can also provide SERENA_TUNNEL_ID and CONTROL_PLANE_API_KEY via environment
variables for non-interactive provisioning. Secrets are never written to Git.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tunnel-id)
      [[ $# -ge 2 ]] || { echo "error: --tunnel-id requires a value" >&2; exit 2; }
      TUNNEL_ID="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "error: unknown option: $1" >&2; usage; exit 2 ;;
    *)
      [[ -z "$PROJECT_PATH" ]] || { echo "error: only one project path is supported" >&2; exit 2; }
      PROJECT_PATH="$1"; shift ;;
  esac
done

[[ "$(id -u)" -eq 0 ]] || { echo "error: run as root" >&2; exit 1; }
[[ -n "$PROJECT_PATH" ]] || { usage; exit 2; }
[[ -d "$PROJECT_PATH" ]] || { echo "error: project does not exist: $PROJECT_PATH" >&2; exit 1; }
PROJECT_PATH="$(cd "$PROJECT_PATH" && pwd -P)"

for tool in python3 curl unzip sha256sum systemctl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: missing required command: $tool" >&2; exit 1; }
done

if [[ -z "$TUNNEL_ID" ]]; then
  read -r -p "OpenAI tunnel ID (tunnel_...): " TUNNEL_ID
fi
[[ "$TUNNEL_ID" == tunnel_* ]] || { echo "error: tunnel id must look like tunnel_..." >&2; exit 1; }

CONTROL_PLANE_KEY="${CONTROL_PLANE_API_KEY:-}"
if [[ -z "$CONTROL_PLANE_KEY" ]]; then
  read -r -s -p "OpenAI Control Plane API key: " CONTROL_PLANE_KEY
  echo
fi
[[ -n "$CONTROL_PLANE_KEY" ]] || { echo "error: API key is required" >&2; exit 1; }

SERENA_BIN="${SERENA_BIN:-$(command -v serena || true)}"
if [[ -n "$SERENA_BIN" && -x "$SERENA_BIN" ]] && [[ "$($SERENA_BIN --version 2>/dev/null || true)" == "Serena 1.7.0" ]]; then
  SERENA_BIN="$(readlink -f "$SERENA_BIN")"
  echo "serena_existing=$SERENA_BIN"
else
  if ! python3 -m venv --help >/dev/null 2>&1; then
    echo "error: Python venv support is required (install your distro's python3-venv package)" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$SERENA_VENV")"
  python3 -m venv "$SERENA_VENV"
  "$SERENA_VENV/bin/python" -m pip install --disable-pip-version-check --upgrade pip
  "$SERENA_VENV/bin/python" -m pip install --disable-pip-version-check "serena-agent==1.7.0"
  SERENA_BIN="$SERENA_VENV/bin/serena"
  [[ "$($SERENA_BIN --version)" == "Serena 1.7.0" ]] || { echo "error: Serena install validation failed" >&2; exit 1; }
  echo "serena_installed=$SERENA_BIN"
fi
SERENA_PYTHON="$(head -n 1 "$SERENA_BIN")"
SERENA_PYTHON="${SERENA_PYTHON#\#!}"

mkdir -p "$(dirname "$SERENA_CONFIG")" "$(dirname "$TUNNEL_PROFILE")"
if [[ ! -f "$SERENA_CONFIG" ]]; then
  HOME=/root "$SERENA_BIN" init -b LSP
fi

if [[ ! -f "$PROJECT_PATH/.serena/project.yml" ]]; then
  HOME=/root "$SERENA_BIN" project create "$PROJECT_PATH"
fi

TUNNEL_DIR="$TUNNEL_DIR" "$SCRIPT_DIR/scripts/update_tunnel_client.sh"

CONTROL_PLANE_API_KEY="$CONTROL_PLANE_KEY" "$SERENA_PYTHON" \
  "$SCRIPT_DIR/scripts/configure_runtime.py" fresh-runtime \
  "$TUNNEL_PROFILE" "$TUNNEL_ENV" "$SYSTEMD_UNIT" "$PROJECT_PATH" "$TUNNEL_ID" \
  --tunnel-dir "$TUNNEL_DIR" --serena-bin "$SERENA_BIN" --health-port "$SERENA_HEALTH_PORT"

CONTROL_PLANE_API_KEY="$CONTROL_PLANE_KEY" \
  "$TUNNEL_DIR/tunnel-client" doctor --profile chatgpt-mcp \
  --health.listen-addr 127.0.0.1:0 >/dev/null
echo "tunnel_doctor=PASS"

unset CONTROL_PLANE_KEY
unset CONTROL_PLANE_API_KEY || true

SERENA_BIN="$SERENA_BIN" SERENA_PYTHON="$SERENA_PYTHON" \
TUNNEL_DIR="$TUNNEL_DIR" TUNNEL_PROFILE="$TUNNEL_PROFILE" TUNNEL_ENV="$TUNNEL_ENV" \
SYSTEMD_UNIT="$SYSTEMD_UNIT" SERENA_CONFIG="$SERENA_CONFIG" SERENA_SERVICE="$SERENA_SERVICE" \
SERENA_HEALTH_PORT="$SERENA_HEALTH_PORT" \
  "$SCRIPT_DIR/install.sh" "$PROJECT_PATH" --skip-tunnel-update --restart

systemctl enable "$SERENA_SERVICE" >/dev/null

TUNNEL_DIR="$TUNNEL_DIR" SERENA_SERVICE="$SERENA_SERVICE" SERENA_HEALTH_PORT="$SERENA_HEALTH_PORT" \
  "$SCRIPT_DIR/scripts/serena-stack-status"

echo "bootstrap=PASS"
echo "next=new ChatGPT/MCP client session may be needed to refresh tool schemas"
