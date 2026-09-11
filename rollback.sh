#!/usr/bin/env bash
set -euo pipefail

RESTART=false
if [[ "${1:-}" == "--restart" ]]; then
  RESTART=true
  shift
fi
[[ $# -eq 0 ]] || { echo "usage: sudo ./rollback.sh [--restart]" >&2; exit 2; }
[[ "$(id -u)" -eq 0 ]] || { echo "error: run as root" >&2; exit 1; }

BACKUP_BASE="${SERENA_BACKUP_BASE:-/root/.serena/lsp-only-kit-backups}"
LATEST="$BACKUP_BASE/latest"
[[ -L "$LATEST" || -d "$LATEST" ]] || { echo "error: no kit backup found at $LATEST" >&2; exit 1; }
BACKUP_DIR="$(readlink -f "$LATEST")"
[[ -f "$BACKUP_DIR/meta.env" ]] || { echo "error: backup metadata missing" >&2; exit 1; }

# shellcheck disable=SC1090
source "$BACKUP_DIR/meta.env"

[[ -d "$PACKAGE_ROOT" ]] || { echo "error: Serena package root missing: $PACKAGE_ROOT" >&2; exit 1; }
cp -a "$BACKUP_DIR/package/tools/__init__.py" "$PACKAGE_ROOT/tools/__init__.py"
if [[ -f "$BACKUP_DIR/package/tools/jetbrains_tools.py" ]]; then
  cp -a "$BACKUP_DIR/package/tools/jetbrains_tools.py" "$PACKAGE_ROOT/tools/jetbrains_tools.py"
fi
cp -a "$BACKUP_DIR/package/config/serena_config.py" "$PACKAGE_ROOT/config/serena_config.py"
cp -a "$BACKUP_DIR/runtime/serena_config.yml" "$SERENA_CONFIG"
cp -a "$BACKUP_DIR/runtime/chatgpt-mcp.yaml" "$TUNNEL_PROFILE"
chmod 0600 "$SERENA_CONFIG" "$TUNNEL_PROFILE"

# Deliberately do not restore an inline CONTROL_PLANE_API_KEY to systemd.
# The root-only EnvironmentFile remains the source of truth.

SERENA_SERVICE="${SERENA_SERVICE:-serena-tunnel.service}"
systemctl daemon-reload
if [[ "$RESTART" == true ]]; then
  systemctl restart "$SERENA_SERVICE"
  echo "service_restarted=yes"
else
  echo "restart_required=yes"
  echo "run: systemctl restart $SERENA_SERVICE"
fi

echo "rollback_from=$BACKUP_DIR"
echo "rollback=PASS"
