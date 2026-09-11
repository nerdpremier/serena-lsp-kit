#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_PATH=""
TUNNEL_ID="${MCP_TUNNEL_ID:-${SERENA_TUNNEL_ID:-}}"
HEALTH_PORT="${MCP_HEALTH_PORT:-18090}"
SERVICE="${MCP_TUNNEL_SERVICE:-serena-tunnel.service}"
BASE_DIR="${MCP_KIT_BASE:-/opt/serena-lsp-kit}"
TUNNEL_DIR="${TUNNEL_DIR:-/root/mcp-workspace/tunnel-client}"
PROFILE="${TUNNEL_PROFILE:-/root/.config/tunnel-client/chatgpt-mcp.yaml}"
ENV_FILE="${TUNNEL_ENV:-/root/.config/tunnel-client/serena-tunnel.env}"
UNIT_FILE="${SYSTEMD_UNIT:-/etc/systemd/system/serena-tunnel.service}"
SERENA_CONFIG="${SERENA_CONFIG:-/root/.serena/serena_config.yml}"
SERENA_VENV="${SERENA_VENV:-$BASE_DIR/serena-venv}"
GITHUB_MCP_DIR="${GITHUB_MCP_DIR:-$BASE_DIR/github-mcp}"
ENABLE_GITHUB=true
ENABLE_PLAYWRIGHT=true

usage() {
  cat <<'EOF'
Usage: sudo ./bootstrap.sh /absolute/path/to/project [options]

Installs one OpenAI tunnel runtime with these MCP channels:
  main        Serena 1.7.0 (LSP-only)
  github      GitHub MCP Server 1.12.1
  playwright  Playwright MCP 0.0.80 (headless + isolated)

Options:
  --tunnel-id tunnel_...  OpenAI tunnel id (otherwise prompted)
  --skip-github           Do not install/configure GitHub MCP
  --skip-playwright       Do not install/configure Playwright MCP

Secrets can be supplied non-interactively with CONTROL_PLANE_API_KEY and
GITHUB_PERSONAL_ACCESS_TOKEN. They are written only to a root-only env file.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tunnel-id) [[ $# -ge 2 ]] || { echo "error: --tunnel-id requires a value" >&2; exit 2; }; TUNNEL_ID="$2"; shift 2 ;;
    --skip-github) ENABLE_GITHUB=false; shift ;;
    --skip-playwright) ENABLE_PLAYWRIGHT=false; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "error: unknown option: $1" >&2; usage; exit 2 ;;
    *) [[ -z "$PROJECT_PATH" ]] || { echo "error: only one project path is supported" >&2; exit 2; }; PROJECT_PATH="$1"; shift ;;
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

CONTROL_KEY="${CONTROL_PLANE_API_KEY:-}"
if [[ -z "$CONTROL_KEY" ]]; then
  read -r -s -p "OpenAI Control Plane API key: " CONTROL_KEY
  echo
fi
[[ -n "$CONTROL_KEY" ]] || { echo "error: Control Plane API key is required" >&2; exit 1; }

GITHUB_TOKEN="${GITHUB_PERSONAL_ACCESS_TOKEN:-}"
if [[ "$ENABLE_GITHUB" == true && -z "$GITHUB_TOKEN" ]]; then
  read -r -s -p "GitHub Personal Access Token: " GITHUB_TOKEN
  echo
fi
if [[ "$ENABLE_GITHUB" == true && -z "$GITHUB_TOKEN" ]]; then
  echo "error: GitHub token is required unless --skip-github is used" >&2
  exit 1
fi

mkdir -p "$BASE_DIR" "$(dirname "$PROFILE")" "$(dirname "$ENV_FILE")"
chmod 0700 "$BASE_DIR"

SERENA_BIN="${SERENA_BIN:-$(command -v serena || true)}"
if [[ -n "$SERENA_BIN" && -x "$SERENA_BIN" ]] && [[ "$($SERENA_BIN --version 2>/dev/null || true)" == "Serena 1.7.0" ]]; then
  SERENA_BIN="$(readlink -f "$SERENA_BIN")"
else
  python3 -m venv "$SERENA_VENV"
  "$SERENA_VENV/bin/python" -m pip install --disable-pip-version-check --upgrade pip >/dev/null
  "$SERENA_VENV/bin/python" -m pip install --disable-pip-version-check "serena-agent==1.7.0" >/dev/null
  SERENA_BIN="$SERENA_VENV/bin/serena"
fi
[[ "$($SERENA_BIN --version 2>/dev/null)" == "Serena 1.7.0" ]] || { echo "error: Serena 1.7.0 validation failed" >&2; exit 1; }
SERENA_PYTHON="$(head -n 1 "$SERENA_BIN")"
SERENA_PYTHON="${SERENA_PYTHON#\#!}"

if [[ ! -f "$SERENA_CONFIG" ]]; then
  HOME=/root "$SERENA_BIN" init -b LSP
fi
if [[ ! -f "$PROJECT_PATH/.serena/project.yml" ]]; then
  HOME=/root "$SERENA_BIN" project create "$PROJECT_PATH"
fi

TUNNEL_DIR="$TUNNEL_DIR" "$SCRIPT_DIR/scripts/update_tunnel_client.sh"

GITHUB_BIN=""
if [[ "$ENABLE_GITHUB" == true ]]; then
  GITHUB_MCP_DIR="$GITHUB_MCP_DIR" "$SCRIPT_DIR/scripts/update_github_mcp.sh"
  GITHUB_BIN="$GITHUB_MCP_DIR/github-mcp-server"
fi

NODE_BIN=""
PLAYWRIGHT_CLI=""
PLAYWRIGHT_BROWSERS=""
if [[ "$ENABLE_PLAYWRIGHT" == true ]]; then
  MCP_KIT_BASE="$BASE_DIR" "$SCRIPT_DIR/scripts/update_node_playwright.sh" >/dev/null
  NODE_BIN="$BASE_DIR/node/bin/node"
  PLAYWRIGHT_CLI="$BASE_DIR/playwright/node_modules/@playwright/mcp/cli.js"
  PLAYWRIGHT_BROWSERS="$BASE_DIR/ms-playwright"
fi

config_args=(
  "$PROFILE" "$ENV_FILE" "$PROJECT_PATH" "$TUNNEL_ID"
  --serena-bin "$SERENA_BIN" --health-port "$HEALTH_PORT"
)
[[ -n "$GITHUB_BIN" ]] && config_args+=(--github-bin "$GITHUB_BIN")
if [[ -n "$NODE_BIN" ]]; then
  config_args+=(--node-bin "$NODE_BIN" --playwright-cli "$PLAYWRIGHT_CLI" --playwright-output-dir "$BASE_DIR/artifacts/playwright")
fi

CONTROL_PLANE_API_KEY="$CONTROL_KEY" GITHUB_PERSONAL_ACCESS_TOKEN="$GITHUB_TOKEN" \
  "$SERENA_PYTHON" "$SCRIPT_DIR/scripts/multi_mcp_config.py" "${config_args[@]}"
if [[ -n "$PLAYWRIGHT_BROWSERS" ]]; then
  printf 'PLAYWRIGHT_BROWSERS_PATH=%s\n' "$PLAYWRIGHT_BROWSERS" >> "$ENV_FILE"
fi
chmod 0600 "$ENV_FILE" "$PROFILE"

cat > "$UNIT_FILE" <<EOF
[Unit]
Description=OpenAI MCP Tunnel (Serena + GitHub + Playwright)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$TUNNEL_DIR
Environment="PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EnvironmentFile=$ENV_FILE
ExecStart=$TUNNEL_DIR/tunnel-client run --profile-file $PROFILE
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
chmod 0600 "$UNIT_FILE"

CONTROL_PLANE_API_KEY="$CONTROL_KEY" GITHUB_PERSONAL_ACCESS_TOKEN="$GITHUB_TOKEN" \
  PLAYWRIGHT_BROWSERS_PATH="$PLAYWRIGHT_BROWSERS" \
  "$TUNNEL_DIR/tunnel-client" doctor --profile-file "$PROFILE" --health.listen-addr 127.0.0.1:0 >/dev/null
echo "tunnel_doctor=PASS"

unset CONTROL_KEY GITHUB_TOKEN CONTROL_PLANE_API_KEY GITHUB_PERSONAL_ACCESS_TOKEN || true

SERENA_BIN="$SERENA_BIN" SERENA_PYTHON="$SERENA_PYTHON" \
TUNNEL_DIR="$TUNNEL_DIR" TUNNEL_PROFILE="$PROFILE" TUNNEL_ENV="$ENV_FILE" \
SYSTEMD_UNIT="$UNIT_FILE" SERENA_CONFIG="$SERENA_CONFIG" SERENA_SERVICE="$SERVICE" \
SERENA_HEALTH_PORT="$HEALTH_PORT" \
  "$SCRIPT_DIR/install.sh" "$PROJECT_PATH" --skip-tunnel-update --restart

systemctl enable "$SERVICE" >/dev/null
install -m 0755 "$SCRIPT_DIR/scripts/mcp-stack-status" /usr/local/sbin/mcp-stack-status

TUNNEL_DIR="$TUNNEL_DIR" MCP_TUNNEL_SERVICE="$SERVICE" MCP_HEALTH_PORT="$HEALTH_PORT" \
  /usr/local/sbin/mcp-stack-status

echo "bootstrap=PASS"
echo "channels=main,github,playwright"
