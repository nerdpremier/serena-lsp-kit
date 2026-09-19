#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_PATH=""
SERENA_TUNNEL_ID="${SERENA_TUNNEL_ID:-}"
GITHUB_TUNNEL_ID="${GITHUB_TUNNEL_ID:-}"
PLAYWRIGHT_TUNNEL_ID="${PLAYWRIGHT_TUNNEL_ID:-}"
STITCH_TUNNEL_ID="${STITCH_TUNNEL_ID:-}"
BASE_DIR="${MCP_KIT_BASE:-/opt/serena-lsp-kit}"
TUNNEL_DIR="${TUNNEL_DIR:-/root/mcp-workspace/tunnel-client}"
PROFILE_DIR="${TUNNEL_PROFILE_DIR:-/root/.config/tunnel-client}"
ENV_DIR="${MCP_ENV_DIR:-/root/.config/mcp-tunnel-kit}"
SERENA_CONFIG="${SERENA_CONFIG:-/root/.serena/serena_config.yml}"
SERENA_VENV="${SERENA_VENV:-$BASE_DIR/serena-venv}"
GITHUB_MCP_DIR="${GITHUB_MCP_DIR:-$BASE_DIR/github-mcp}"
STITCH_MCP_DIR="${STITCH_MCP_DIR:-$BASE_DIR/stitch-mcp}"
ENABLE_GITHUB=true
ENABLE_PLAYWRIGHT=true
ENABLE_STITCH=true

SERENA_PROFILE="$PROFILE_DIR/serena.yaml"
GITHUB_PROFILE="$PROFILE_DIR/github.yaml"
PLAYWRIGHT_PROFILE="$PROFILE_DIR/playwright.yaml"
STITCH_PROFILE="$PROFILE_DIR/stitch.yaml"
SERENA_ENV="$ENV_DIR/serena.env"
GITHUB_ENV="$ENV_DIR/github.env"
PLAYWRIGHT_ENV="$ENV_DIR/playwright.env"
STITCH_ENV="$ENV_DIR/stitch.env"
SERENA_UNIT="/etc/systemd/system/mcp-serena-tunnel.service"
GITHUB_UNIT="/etc/systemd/system/mcp-github-tunnel.service"
PLAYWRIGHT_UNIT="/etc/systemd/system/mcp-playwright-tunnel.service"
STITCH_UNIT="/etc/systemd/system/mcp-stitch-tunnel.service"

usage() {
  cat <<'EOF'
Usage: sudo ./bootstrap.sh /absolute/path/to/project [options]

Installs four independent OpenAI MCP tunnels/connectors:
  Serena      tunnel -> channel main -> Serena 1.7.0 (LSP-only)
  GitHub      tunnel -> channel main -> GitHub MCP Server 1.12.1
  Playwright  tunnel -> channel main -> Playwright MCP 0.0.80
  Stitch      tunnel -> channel main -> Google Stitch MCP

Options:
  --serena-tunnel-id tunnel_...
  --github-tunnel-id tunnel_...
  --playwright-tunnel-id tunnel_...
  --stitch-tunnel-id tunnel_...
  --skip-github
  --skip-playwright
  --skip-stitch

CONTROL_PLANE_API_KEY is shared by the installed tunnel processes.
GITHUB_PERSONAL_ACCESS_TOKEN is injected only into the GitHub MCP tunnel.
STITCH_API_KEY is injected only into the Stitch MCP tunnel.

Playwright Linux mode:
  MCP_PLAYWRIGHT_HEADLESS=0   Show Chromium on the active desktop session (default)
  MCP_PLAYWRIGHT_HEADLESS=1   Headless Chromium
  MCP_PLAYWRIGHT_USER=user    Override the Linux desktop/runtime user
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --serena-tunnel-id) [[ $# -ge 2 ]] || exit 2; SERENA_TUNNEL_ID="$2"; shift 2 ;;
    --github-tunnel-id) [[ $# -ge 2 ]] || exit 2; GITHUB_TUNNEL_ID="$2"; shift 2 ;;
    --playwright-tunnel-id) [[ $# -ge 2 ]] || exit 2; PLAYWRIGHT_TUNNEL_ID="$2"; shift 2 ;;
    --stitch-tunnel-id) [[ $# -ge 2 ]] || exit 2; STITCH_TUNNEL_ID="$2"; shift 2 ;;
    --skip-github) ENABLE_GITHUB=false; shift ;;
    --skip-playwright) ENABLE_PLAYWRIGHT=false; shift ;;
    --skip-stitch) ENABLE_STITCH=false; shift ;;
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

prompt_tunnel() {
  local var_name="$1" label="$2" value
  value="${!var_name}"
  if [[ -z "$value" ]]; then
    read -r -p "$label tunnel ID (tunnel_...): " value
    printf -v "$var_name" '%s' "$value"
  fi
  [[ "$value" =~ ^tunnel_[a-z0-9]{32}$ ]] || { echo "error: $label tunnel id must look like tunnel_..." >&2; exit 1; }
}

prompt_tunnel SERENA_TUNNEL_ID Serena
[[ "$ENABLE_GITHUB" == true ]] && prompt_tunnel GITHUB_TUNNEL_ID GitHub
[[ "$ENABLE_PLAYWRIGHT" == true ]] && prompt_tunnel PLAYWRIGHT_TUNNEL_ID Playwright
[[ "$ENABLE_STITCH" == true ]] && prompt_tunnel STITCH_TUNNEL_ID Stitch

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
[[ "$ENABLE_GITHUB" == false || -n "$GITHUB_TOKEN" ]] || { echo "error: GitHub token is required" >&2; exit 1; }

STITCH_KEY="${STITCH_API_KEY:-}"
if [[ "$ENABLE_STITCH" == true && -z "$STITCH_KEY" ]]; then
  read -r -s -p "Google Stitch API key: " STITCH_KEY
  echo
fi
[[ "$ENABLE_STITCH" == false || -n "$STITCH_KEY" ]] || { echo "error: Stitch API key is required" >&2; exit 1; }

mkdir -p "$BASE_DIR" "$PROFILE_DIR" "$ENV_DIR"
chmod 0700 "$BASE_DIR" "$ENV_DIR"

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

if [[ ! -f "$SERENA_CONFIG" ]]; then HOME=/root "$SERENA_BIN" init -b LSP; fi
if [[ ! -f "$PROJECT_PATH/.serena/project.yml" ]]; then HOME=/root "$SERENA_BIN" project create "$PROJECT_PATH"; fi

TUNNEL_DIR="$TUNNEL_DIR" "$SCRIPT_DIR/scripts/update_tunnel_client.sh"
TUNNEL_VERSION_FILE="/usr/local/share/mcp-tunnel-kit/tunnel-client.version"
install -d -m 0755 "$(dirname "$TUNNEL_VERSION_FILE")"
"$TUNNEL_DIR/tunnel-client" --version >"$TUNNEL_VERSION_FILE"
chmod 0644 "$TUNNEL_VERSION_FILE"

GITHUB_BIN=""
if [[ "$ENABLE_GITHUB" == true ]]; then
  GITHUB_MCP_DIR="$GITHUB_MCP_DIR" "$SCRIPT_DIR/scripts/update_github_mcp.sh"
  GITHUB_BIN="$GITHUB_MCP_DIR/github-mcp-server"
fi

NODE_BIN=""
PLAYWRIGHT_CLI=""
PLAYWRIGHT_BROWSERS=""
PLAYWRIGHT_BROWSER=""
PLAYWRIGHT_USER=""
PLAYWRIGHT_GUI_ARGS=()
if [[ "$ENABLE_PLAYWRIGHT" == true ]]; then
  command -v runuser >/dev/null 2>&1 || { echo "error: missing required command: runuser" >&2; exit 1; }
  case "${MCP_PLAYWRIGHT_HEADLESS:-0}" in
    1|true|TRUE|yes|YES|on|ON) PLAYWRIGHT_HEADLESS=true ;;
    0|false|FALSE|no|NO|off|OFF) PLAYWRIGHT_HEADLESS=false ;;
    *) echo "error: MCP_PLAYWRIGHT_HEADLESS must be 1/0, true/false, yes/no, or on/off" >&2; exit 1 ;;
  esac
  active_desktop_user() {
    local session user active type
    if command -v loginctl >/dev/null 2>&1; then
      while read -r session _ user _ _; do
        [[ -n "$session" && -n "$user" && "$user" != root ]] || continue
        active="$(loginctl show-session "$session" -p Active --value 2>/dev/null || true)"
        type="$(loginctl show-session "$session" -p Type --value 2>/dev/null || true)"
        if [[ "$active" == yes && ( "$type" == x11 || "$type" == wayland ) ]]; then printf '%s' "$user"; return 0; fi
      done < <(loginctl list-sessions --no-legend 2>/dev/null || true)
    fi
    if command -v who >/dev/null 2>&1; then
      user="$(who | awk '$0 ~ /\(:[0-9]+(\.[0-9]+)?\)/ {print $1; exit}')"
      if [[ -n "$user" && "$user" != root ]]; then printf '%s' "$user"; return 0; fi
    fi
    return 1
  }
  PLAYWRIGHT_USER="${MCP_PLAYWRIGHT_USER:-${SUDO_USER:-}}"
  if [[ -z "$PLAYWRIGHT_USER" || "$PLAYWRIGHT_USER" == root ]]; then
    if [[ "$PLAYWRIGHT_HEADLESS" == false ]]; then PLAYWRIGHT_USER="$(active_desktop_user || true)"; fi
    if [[ -z "$PLAYWRIGHT_USER" || "$PLAYWRIGHT_USER" == root ]]; then
      PLAYWRIGHT_USER="mcp-playwright"
      if ! id "$PLAYWRIGHT_USER" >/dev/null 2>&1; then
        command -v useradd >/dev/null 2>&1 || { echo "error: useradd is required when installing Playwright directly as root" >&2; exit 1; }
        useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$PLAYWRIGHT_USER"
      fi
    fi
  fi
  id "$PLAYWRIGHT_USER" >/dev/null 2>&1 || { echo "error: Playwright runtime user does not exist: $PLAYWRIGHT_USER" >&2; exit 1; }
  MCP_KIT_BASE="$BASE_DIR" "$SCRIPT_DIR/scripts/update_node_playwright.sh" >/dev/null
  NODE_BIN="$BASE_DIR/node/bin/node"
  PLAYWRIGHT_CLI="$BASE_DIR/playwright/node_modules/@playwright/mcp/cli.js"
  PLAYWRIGHT_BROWSERS="$BASE_DIR/ms-playwright"
  PLAYWRIGHT_BROWSER="$(find "$PLAYWRIGHT_BROWSERS" -type f -path '*/chromium-*/*' -name chrome -perm -111 -print -quit)"
  [[ -x "$PLAYWRIGHT_BROWSER" ]] || { echo "error: installed Playwright Chromium executable not found" >&2; exit 1; }
  chmod 0755 "$BASE_DIR"
  PLAYWRIGHT_GROUP="$(id -gn "$PLAYWRIGHT_USER")"
  install -d -o "$PLAYWRIGHT_USER" -g "$PLAYWRIGHT_GROUP" -m 0750 "$BASE_DIR/artifacts/playwright"
  if [[ "$PLAYWRIGHT_HEADLESS" == false ]]; then
    command -v pgrep >/dev/null 2>&1 || { echo "error: pgrep is required for Playwright GUI mode" >&2; exit 1; }
    desktop_env_value() {
      local key="$1" pid value
      while read -r pid; do
        [[ -n "$pid" && -r "/proc/$pid/environ" ]] || continue
        value="$(tr '\0' '\n' <"/proc/$pid/environ" | sed -n "s/^${key}=//p" | head -n 1)"
        if [[ -n "$value" ]]; then printf '%s' "$value"; return 0; fi
      done < <(pgrep -u "$PLAYWRIGHT_USER" -f 'xfce4-session|gnome-session|plasmashell|ksmserver|Xorg|Xwayland' 2>/dev/null || true)
      return 1
    }
    PLAYWRIGHT_DISPLAY="${MCP_PLAYWRIGHT_DISPLAY:-$(desktop_env_value DISPLAY || true)}"
    PLAYWRIGHT_WAYLAND_DISPLAY="${MCP_PLAYWRIGHT_WAYLAND_DISPLAY:-$(desktop_env_value WAYLAND_DISPLAY || true)}"
    PLAYWRIGHT_XAUTHORITY="${MCP_PLAYWRIGHT_XAUTHORITY:-$(desktop_env_value XAUTHORITY || true)}"
    PLAYWRIGHT_XDG_RUNTIME_DIR="${MCP_PLAYWRIGHT_XDG_RUNTIME_DIR:-$(desktop_env_value XDG_RUNTIME_DIR || true)}"
    PLAYWRIGHT_DBUS_SESSION_BUS_ADDRESS="${MCP_PLAYWRIGHT_DBUS_SESSION_BUS_ADDRESS:-$(desktop_env_value DBUS_SESSION_BUS_ADDRESS || true)}"
    PLAYWRIGHT_UID="$(id -u "$PLAYWRIGHT_USER")"
    [[ -n "$PLAYWRIGHT_XDG_RUNTIME_DIR" ]] || PLAYWRIGHT_XDG_RUNTIME_DIR="/run/user/$PLAYWRIGHT_UID"
    if [[ -z "$PLAYWRIGHT_XAUTHORITY" ]]; then
      PLAYWRIGHT_HOME="$(getent passwd "$PLAYWRIGHT_USER" | cut -d: -f6)"
      [[ -f "$PLAYWRIGHT_HOME/.Xauthority" ]] && PLAYWRIGHT_XAUTHORITY="$PLAYWRIGHT_HOME/.Xauthority"
    fi
    if [[ -z "$PLAYWRIGHT_DBUS_SESSION_BUS_ADDRESS" && -S "$PLAYWRIGHT_XDG_RUNTIME_DIR/bus" ]]; then PLAYWRIGHT_DBUS_SESSION_BUS_ADDRESS="unix:path=$PLAYWRIGHT_XDG_RUNTIME_DIR/bus"; fi
    if [[ -z "$PLAYWRIGHT_DISPLAY" && -z "$PLAYWRIGHT_WAYLAND_DISPLAY" ]]; then
      echo "error: Playwright GUI mode could not find an active desktop session for $PLAYWRIGHT_USER" >&2
      echo "hint: set MCP_PLAYWRIGHT_DISPLAY or MCP_PLAYWRIGHT_WAYLAND_DISPLAY explicitly" >&2
      exit 1
    fi
    PLAYWRIGHT_GUI_ARGS=(--headed)
    [[ -n "$PLAYWRIGHT_DISPLAY" ]] && PLAYWRIGHT_GUI_ARGS+=(--display "$PLAYWRIGHT_DISPLAY")
    [[ -n "$PLAYWRIGHT_WAYLAND_DISPLAY" ]] && PLAYWRIGHT_GUI_ARGS+=(--wayland-display "$PLAYWRIGHT_WAYLAND_DISPLAY")
    [[ -n "$PLAYWRIGHT_XAUTHORITY" ]] && PLAYWRIGHT_GUI_ARGS+=(--xauthority "$PLAYWRIGHT_XAUTHORITY")
    [[ -n "$PLAYWRIGHT_XDG_RUNTIME_DIR" ]] && PLAYWRIGHT_GUI_ARGS+=(--xdg-runtime-dir "$PLAYWRIGHT_XDG_RUNTIME_DIR")
    [[ -n "$PLAYWRIGHT_DBUS_SESSION_BUS_ADDRESS" ]] && PLAYWRIGHT_GUI_ARGS+=(--dbus-session-bus-address "$PLAYWRIGHT_DBUS_SESSION_BUS_ADDRESS")
  fi
fi

if [[ "$ENABLE_STITCH" == true && -z "$NODE_BIN" ]]; then
  MCP_KIT_BASE="$BASE_DIR" "$SCRIPT_DIR/scripts/update_node.sh" >/dev/null
  NODE_BIN="$BASE_DIR/node/bin/node"
fi
STITCH_SERVER=""
if [[ "$ENABLE_STITCH" == true ]]; then
  install -d -m 0755 "$STITCH_MCP_DIR"
  install -m 0644 "$SCRIPT_DIR/stitch-mcp/package.json" "$STITCH_MCP_DIR/package.json"
  install -m 0644 "$SCRIPT_DIR/stitch-mcp/server.mjs" "$STITCH_MCP_DIR/server.mjs"
  install -m 0644 "$SCRIPT_DIR/stitch-mcp/worker.mjs" "$STITCH_MCP_DIR/worker.mjs"
  PATH="$BASE_DIR/node/bin:$PATH" "$BASE_DIR/node/bin/npm" install --prefix "$STITCH_MCP_DIR" --omit=dev --no-audit --no-fund >/dev/null
  STITCH_SERVER="$STITCH_MCP_DIR/server.mjs"
  "$NODE_BIN" --check "$STITCH_SERVER" >/dev/null
  "$NODE_BIN" --check "$STITCH_MCP_DIR/worker.mjs" >/dev/null
fi

CONTROL_PLANE_API_KEY="$CONTROL_KEY" "$SERENA_PYTHON" "$SCRIPT_DIR/scripts/multi_mcp_config.py" serena "$SERENA_PROFILE" "$SERENA_ENV" "$SERENA_TUNNEL_ID" --health-port 18090 "$PROJECT_PATH" --serena-bin "$SERENA_BIN"
if [[ "$ENABLE_GITHUB" == true ]]; then CONTROL_PLANE_API_KEY="$CONTROL_KEY" GITHUB_PERSONAL_ACCESS_TOKEN="$GITHUB_TOKEN" "$SERENA_PYTHON" "$SCRIPT_DIR/scripts/multi_mcp_config.py" github "$GITHUB_PROFILE" "$GITHUB_ENV" "$GITHUB_TUNNEL_ID" --health-port 18091 --github-bin "$GITHUB_BIN"; fi
if [[ "$ENABLE_PLAYWRIGHT" == true ]]; then
  CONTROL_PLANE_API_KEY="$CONTROL_KEY" "$SERENA_PYTHON" "$SCRIPT_DIR/scripts/multi_mcp_config.py" playwright "$PLAYWRIGHT_PROFILE" "$PLAYWRIGHT_ENV" "$PLAYWRIGHT_TUNNEL_ID" --health-port 18092 --node-bin "$NODE_BIN" --playwright-cli "$PLAYWRIGHT_CLI" --output-dir "$BASE_DIR/artifacts/playwright" --browsers-path "$PLAYWRIGHT_BROWSERS" --browser-executable "$PLAYWRIGHT_BROWSER" --run-as-user "$PLAYWRIGHT_USER" "${PLAYWRIGHT_GUI_ARGS[@]}"
fi
if [[ "$ENABLE_STITCH" == true ]]; then CONTROL_PLANE_API_KEY="$CONTROL_KEY" STITCH_API_KEY="$STITCH_KEY" "$SERENA_PYTHON" "$SCRIPT_DIR/scripts/multi_mcp_config.py" stitch "$STITCH_PROFILE" "$STITCH_ENV" "$STITCH_TUNNEL_ID" --health-port 18093 "$PROJECT_PATH" --node-bin "$NODE_BIN" --stitch-server "$STITCH_SERVER"; fi
chmod 0600 "$PROFILE_DIR"/*.yaml "$ENV_DIR"/*.env

write_unit() {
  local unit="$1" description="$2" env_file="$3" profile="$4"
  cat > "$unit" <<EOF
[Unit]
Description=$description
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$TUNNEL_DIR
Environment="PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EnvironmentFile=$env_file
ExecStart=$TUNNEL_DIR/tunnel-client run --profile-file $profile
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
  chmod 0600 "$unit"
}
write_unit "$SERENA_UNIT" "OpenAI MCP Tunnel - Serena" "$SERENA_ENV" "$SERENA_PROFILE"
[[ "$ENABLE_GITHUB" == true ]] && write_unit "$GITHUB_UNIT" "OpenAI MCP Tunnel - GitHub" "$GITHUB_ENV" "$GITHUB_PROFILE"
[[ "$ENABLE_PLAYWRIGHT" == true ]] && write_unit "$PLAYWRIGHT_UNIT" "OpenAI MCP Tunnel - Playwright" "$PLAYWRIGHT_ENV" "$PLAYWRIGHT_PROFILE"
[[ "$ENABLE_STITCH" == true ]] && write_unit "$STITCH_UNIT" "OpenAI MCP Tunnel - Stitch" "$STITCH_ENV" "$STITCH_PROFILE"

CONTROL_PLANE_API_KEY="$CONTROL_KEY" "$TUNNEL_DIR/tunnel-client" doctor --profile-file "$SERENA_PROFILE" --health.listen-addr 127.0.0.1:0 >/dev/null
if [[ "$ENABLE_GITHUB" == true ]]; then CONTROL_PLANE_API_KEY="$CONTROL_KEY" GITHUB_PERSONAL_ACCESS_TOKEN="$GITHUB_TOKEN" "$TUNNEL_DIR/tunnel-client" doctor --profile-file "$GITHUB_PROFILE" --health.listen-addr 127.0.0.1:0 >/dev/null; fi
if [[ "$ENABLE_PLAYWRIGHT" == true ]]; then CONTROL_PLANE_API_KEY="$CONTROL_KEY" PLAYWRIGHT_BROWSERS_PATH="$PLAYWRIGHT_BROWSERS" "$TUNNEL_DIR/tunnel-client" doctor --profile-file "$PLAYWRIGHT_PROFILE" --health.listen-addr 127.0.0.1:0 >/dev/null; fi
if [[ "$ENABLE_STITCH" == true ]]; then CONTROL_PLANE_API_KEY="$CONTROL_KEY" STITCH_API_KEY="$STITCH_KEY" "$TUNNEL_DIR/tunnel-client" doctor --profile-file "$STITCH_PROFILE" --health.listen-addr 127.0.0.1:0 >/dev/null; fi
echo "tunnel_doctor=PASS"

if systemctl cat serena-tunnel.service >/dev/null 2>&1; then systemctl disable --now serena-tunnel.service >/dev/null 2>&1 || true; echo "legacy_bundle_service=disabled"; fi
SERENA_BIN="$SERENA_BIN" SERENA_PYTHON="$SERENA_PYTHON" TUNNEL_DIR="$TUNNEL_DIR" TUNNEL_PROFILE="$SERENA_PROFILE" TUNNEL_ENV="$SERENA_ENV" SYSTEMD_UNIT="$SERENA_UNIT" SERENA_CONFIG="$SERENA_CONFIG" SERENA_SERVICE="mcp-serena-tunnel.service" SERENA_HEALTH_PORT=18090 "$SCRIPT_DIR/install.sh" "$PROJECT_PATH" --skip-tunnel-update --restart

systemctl daemon-reload
systemctl enable mcp-serena-tunnel.service >/dev/null
[[ "$ENABLE_GITHUB" == true ]] && systemctl enable --now mcp-github-tunnel.service >/dev/null
[[ "$ENABLE_PLAYWRIGHT" == true ]] && systemctl enable --now mcp-playwright-tunnel.service >/dev/null
[[ "$ENABLE_STITCH" == true ]] && systemctl enable --now mcp-stitch-tunnel.service >/dev/null
sleep 2
install -m 0755 "$SCRIPT_DIR/scripts/mcp-stack-status" /usr/local/sbin/mcp-stack-status
unset CONTROL_KEY GITHUB_TOKEN STITCH_KEY CONTROL_PLANE_API_KEY GITHUB_PERSONAL_ACCESS_TOKEN STITCH_API_KEY || true
/usr/local/sbin/mcp-stack-status
echo "bootstrap=PASS"
connectors=(serena)
[[ "$ENABLE_GITHUB" == true ]] && connectors+=(github)
[[ "$ENABLE_PLAYWRIGHT" == true ]] && connectors+=(playwright)
[[ "$ENABLE_STITCH" == true ]] && connectors+=(stitch)
(IFS=,; echo "connectors=${connectors[*]}")
