#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RESTART=false
SKIP_TUNNEL_UPDATE=false
PROJECT_PATH=""

usage() {
  cat <<'EOF'
Usage: sudo ./install.sh /absolute/path/to/project [--restart] [--skip-tunnel-update]

Hardens an existing Serena 1.7.0 + tunnel-client installation. For a new
machine, use bootstrap.sh instead.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --restart) RESTART=true; shift ;;
    --skip-tunnel-update) SKIP_TUNNEL_UPDATE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "error: unknown option: $1" >&2; usage; exit 2 ;;
    *)
      [[ -z "$PROJECT_PATH" ]] || { echo "error: only one project path is supported" >&2; exit 2; }
      PROJECT_PATH="$1"
      shift
      ;;
  esac
done

[[ "$(id -u)" -eq 0 ]] || { echo "error: run as root" >&2; exit 1; }
[[ -n "$PROJECT_PATH" ]] || { usage; exit 2; }
[[ -d "$PROJECT_PATH" ]] || { echo "error: project does not exist: $PROJECT_PATH" >&2; exit 1; }
PROJECT_PATH="$(cd "$PROJECT_PATH" && pwd -P)"

SERENA_BIN="${SERENA_BIN:-$(command -v serena || true)}"
[[ -n "$SERENA_BIN" && -x "$SERENA_BIN" ]] || { echo "error: serena executable not found" >&2; exit 1; }
SERENA_BIN="$(readlink -f "$SERENA_BIN")"

if [[ -z "${SERENA_PYTHON:-}" ]]; then
  first_line="$(head -n 1 "$SERENA_BIN")"
  [[ "$first_line" == '#!'* ]] || { echo "error: cannot derive Serena Python from $SERENA_BIN" >&2; exit 1; }
  SERENA_PYTHON="${first_line#\#!}"
fi
[[ -x "$SERENA_PYTHON" ]] || { echo "error: Serena Python is not executable: $SERENA_PYTHON" >&2; exit 1; }

SERENA_VERSION="$($SERENA_BIN --version 2>/dev/null || true)"
[[ "$SERENA_VERSION" == "Serena 1.7.0" ]] || {
  echo "error: this kit is pinned to Serena 1.7.0; found: ${SERENA_VERSION:-unknown}" >&2
  exit 1
}

PACKAGE_ROOT="$($SERENA_PYTHON -c 'import pathlib, serena; print(pathlib.Path(serena.__file__).resolve().parent)')"
SERENA_CONFIG="${SERENA_CONFIG:-/root/.serena/serena_config.yml}"
TUNNEL_DIR="${TUNNEL_DIR:-/root/mcp-workspace/tunnel-client}"
TUNNEL_PROFILE="${TUNNEL_PROFILE:-/root/.config/tunnel-client/chatgpt-mcp.yaml}"
TUNNEL_ENV="${TUNNEL_ENV:-/root/.config/tunnel-client/serena-tunnel.env}"
SYSTEMD_UNIT="${SYSTEMD_UNIT:-/etc/systemd/system/serena-tunnel.service}"
SERENA_SERVICE="${SERENA_SERVICE:-serena-tunnel.service}"
SERENA_HEALTH_PORT="${SERENA_HEALTH_PORT:-18090}"
BACKUP_BASE="${SERENA_BACKUP_BASE:-/root/.serena/lsp-only-kit-backups}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="$BACKUP_BASE/$STAMP"

for required in "$SERENA_CONFIG" "$TUNNEL_PROFILE" "$SYSTEMD_UNIT" \
  "$PACKAGE_ROOT/tools/__init__.py" "$PACKAGE_ROOT/config/serena_config.py"; do
  [[ -e "$required" ]] || { echo "error: missing required file: $required" >&2; exit 1; }
done

mkdir -p "$BACKUP_DIR/package/tools" "$BACKUP_DIR/package/config" "$BACKUP_DIR/runtime"
chmod 0700 "$BACKUP_DIR"
cp -a "$PACKAGE_ROOT/tools/__init__.py" "$BACKUP_DIR/package/tools/__init__.py"
[[ -e "$PACKAGE_ROOT/tools/jetbrains_tools.py" ]] && \
  cp -a "$PACKAGE_ROOT/tools/jetbrains_tools.py" "$BACKUP_DIR/package/tools/jetbrains_tools.py"
cp -a "$PACKAGE_ROOT/config/serena_config.py" "$BACKUP_DIR/package/config/serena_config.py"
cp -a "$SERENA_CONFIG" "$BACKUP_DIR/runtime/serena_config.yml"
cp -a "$TUNNEL_PROFILE" "$BACKUP_DIR/runtime/chatgpt-mcp.yaml"
printf 'PACKAGE_ROOT=%q\nSERENA_CONFIG=%q\nTUNNEL_PROFILE=%q\nPROJECT_PATH=%q\n' \
  "$PACKAGE_ROOT" "$SERENA_CONFIG" "$TUNNEL_PROFILE" "$PROJECT_PATH" > "$BACKUP_DIR/meta.env"
chmod 0600 "$BACKUP_DIR/meta.env"
ln -sfn "$BACKUP_DIR" "$BACKUP_BASE/latest"

echo "backup=$BACKUP_DIR"

if [[ "$SKIP_TUNNEL_UPDATE" == false ]]; then
  TUNNEL_DIR="$TUNNEL_DIR" "$SCRIPT_DIR/scripts/update_tunnel_client.sh"
fi

"$SERENA_PYTHON" "$SCRIPT_DIR/scripts/configure_runtime.py" serena-global "$SERENA_CONFIG"
"$SERENA_PYTHON" "$SCRIPT_DIR/scripts/configure_runtime.py" project-local "$PROJECT_PATH/.serena/project.local.yml"
"$SERENA_PYTHON" "$SCRIPT_DIR/scripts/configure_runtime.py" \
  tunnel-profile "$TUNNEL_PROFILE" "$PROJECT_PATH" \
  --health-port "$SERENA_HEALTH_PORT" --serena-bin "$SERENA_BIN"
"$SERENA_PYTHON" "$SCRIPT_DIR/scripts/configure_runtime.py" \
  systemd-secret "$SYSTEMD_UNIT" "$TUNNEL_ENV"
"$SERENA_PYTHON" "$SCRIPT_DIR/scripts/patch_serena.py" "$PACKAGE_ROOT"

install -m 0755 "$SCRIPT_DIR/scripts/serena-stack-status" /usr/local/sbin/serena-stack-status
install -m 0700 "$SCRIPT_DIR/scripts/rotate-serena-control-plane-key" /usr/local/sbin/rotate-mcp-control-plane-key
install -m 0700 "$SCRIPT_DIR/scripts/rotate-serena-control-plane-key" /usr/local/sbin/rotate-serena-control-plane-key

SERENA_PACKAGE_ROOT="$PACKAGE_ROOT" "$SERENA_PYTHON" - <<'PY'
import os
from pathlib import Path
from serena.config.serena_config import LanguageBackend
from serena.tools import ToolRegistry

root = Path(os.environ["SERENA_PACKAGE_ROOT"])
assert not (root / "tools" / "jetbrains_tools.py").exists()
names = ToolRegistry().get_tool_names()
assert not [name for name in names if name.startswith("jet_brains_")], names
assert LanguageBackend.LSP.get_lsp_tool_class_replacements() == {}
try:
    LanguageBackend.JETBRAINS.get_lsp_tool_class_replacements()
except RuntimeError as exc:
    assert "LSP-only" in str(exc)
else:
    raise AssertionError("JetBrains backend unexpectedly remained enabled")
print("serena_lsp_only_validation=PASS")
PY

systemctl daemon-reload

if [[ "$RESTART" == true ]]; then
  systemctl restart "$SERENA_SERVICE"
  sleep 2
  health="$(curl -fsS "http://127.0.0.1:${SERENA_HEALTH_PORT}/healthz" || true)"
  ready="$(curl -fsS "http://127.0.0.1:${SERENA_HEALTH_PORT}/readyz" || true)"
  [[ "$health" == "live" && "$ready" == "ready" ]] || {
    echo "error: service restarted but health check failed (health=$health ready=$ready)" >&2
    exit 1
  }
  echo "restart_validation=PASS"
else
  echo "restart_required=yes"
  echo "run: systemctl restart $SERENA_SERVICE"
fi

echo "install=PASS"
