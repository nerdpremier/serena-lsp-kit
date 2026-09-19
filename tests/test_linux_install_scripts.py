from __future__ import annotations

import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP = ROOT / "bootstrap.sh"
UPDATE_NODE = ROOT / "scripts" / "update_node.sh"
UPDATE_PLAYWRIGHT = ROOT / "scripts" / "update_node_playwright.sh"


class LinuxInstallScriptTests(unittest.TestCase):
    def test_shell_scripts_parse(self) -> None:
        subprocess.run(["bash", "-n", str(BOOTSTRAP)], check=True)
        subprocess.run(["bash", "-n", str(UPDATE_NODE)], check=True)
        subprocess.run(["bash", "-n", str(UPDATE_PLAYWRIGHT)], check=True)

    def test_managed_node_is_used_when_running_npm(self) -> None:
        node_script = UPDATE_NODE.read_text(encoding="utf-8")
        playwright_script = UPDATE_PLAYWRIGHT.read_text(encoding="utf-8")
        bootstrap_script = BOOTSTRAP.read_text(encoding="utf-8")

        self.assertIn(
            'NPM_CLI="$NODE_DIR/lib/node_modules/npm/bin/npm-cli.js"',
            node_script,
        )
        self.assertIn(
            '"$NODE_DIR/bin/node" "$NPM_CLI" --version',
            node_script,
        )
        self.assertNotIn('"$NODE_DIR/bin/npm" --version', node_script)

        self.assertIn(
            '"$NODE_DIR/bin/node" "$NPM_CLI" install',
            playwright_script,
        )
        self.assertNotIn('"$NODE_DIR/bin/npm" install', playwright_script)
        self.assertIn('"$SCRIPT_DIR/update_node.sh"', playwright_script)

        self.assertIn(
            'NODE_NPM_CLI="$BASE_DIR/node/lib/node_modules/npm/bin/npm-cli.js"',
            bootstrap_script,
        )
        self.assertIn(
            '"$NODE_BIN" "$NODE_NPM_CLI" install --loglevel=error --prefix "$STITCH_MCP_DIR"',
            bootstrap_script,
        )
        self.assertNotIn('"$BASE_DIR/node/bin/npm" install', bootstrap_script)
        self.assertIn(
            '"$NODE_DIR/bin/node" "$NPM_CLI" install --loglevel=error',
            playwright_script,
        )
        self.assertIn(
            '"$NODE_BIN" "$NODE_NPM_CLI" install --loglevel=error',
            bootstrap_script,
        )

    def test_bootstrap_does_not_depend_on_helper_execute_bits(self) -> None:
        script = BOOTSTRAP.read_text(encoding="utf-8")
        playwright_script = UPDATE_PLAYWRIGHT.read_text(encoding="utf-8")

        for helper in (
            "scripts/update_tunnel_client.sh",
            "scripts/update_github_mcp.sh",
            "scripts/update_node_playwright.sh",
            "scripts/update_node.sh",
            "install.sh",
        ):
            self.assertIn(f'bash "$SCRIPT_DIR/{helper}"', script)
        self.assertIn('bash "$SCRIPT_DIR/update_node.sh"', playwright_script)
        self.assertNotEqual(BOOTSTRAP.stat().st_mode & 0o100, 0)

    def test_root_gui_install_auto_detects_active_desktop_user(self) -> None:
        script = BOOTSTRAP.read_text(encoding="utf-8")
        self.assertIn("active_desktop_user()", script)
        self.assertIn('loginctl show-session "$session" -p Type --value', script)
        self.assertIn('if [[ "$PLAYWRIGHT_HEADLESS" == false ]]; then', script)
        self.assertIn('PLAYWRIGHT_USER="$(active_desktop_user || true)"', script)
        self.assertIn('PLAYWRIGHT_USER="mcp-playwright"', script)

    def test_stitch_bootstrap_is_isolated_and_optional(self) -> None:
        script = BOOTSTRAP.read_text(encoding="utf-8")
        self.assertIn('STITCH_TUNNEL_ID="${STITCH_TUNNEL_ID:-}"', script)
        self.assertIn('--skip-stitch', script)
        self.assertIn('STITCH_API_KEY="$STITCH_KEY"', script)
        self.assertIn('mcp-stitch-tunnel.service', script)
        self.assertIn('--health-port 18093', script)
        self.assertIn('stitch-mcp/server.mjs', script)


if __name__ == "__main__":
    unittest.main()
