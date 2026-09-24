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

        self.assertNotIn('"$BASE_DIR/node/bin/npm" install', bootstrap_script)
        self.assertIn(
            '"$NODE_DIR/bin/node" "$NPM_CLI" install --loglevel=error',
            playwright_script,
        )

    def test_bootstrap_does_not_depend_on_helper_execute_bits(self) -> None:
        script = BOOTSTRAP.read_text(encoding="utf-8")
        playwright_script = UPDATE_PLAYWRIGHT.read_text(encoding="utf-8")

        for helper in (
            "scripts/update_tunnel_client.sh",
            "scripts/update_node_playwright.sh",
            "install.sh",
        ):
            self.assertIn(f'bash "$SCRIPT_DIR/{helper}"', script)
        self.assertIn('bash "$SCRIPT_DIR/update_node.sh"', playwright_script)
        self.assertNotEqual(BOOTSTRAP.stat().st_mode & 0o100, 0)

    def test_bootstrap_removes_legacy_github_connector(self) -> None:
        script = BOOTSTRAP.read_text(encoding="utf-8")
        self.assertIn("remove_legacy_github_connector", script)
        self.assertIn("systemctl disable --now mcp-github-tunnel.service", script)
        self.assertIn('"$PROFILE_DIR/github.yaml"', script)
        self.assertIn('"$ENV_DIR/github.env"', script)
        self.assertIn('"$BASE_DIR/github-mcp"', script)
        self.assertNotIn("GITHUB_TUNNEL_ID", script)
        self.assertNotIn("GITHUB_PERSONAL_ACCESS_TOKEN", script)
        self.assertNotIn("--skip-github", script)

    def test_root_gui_install_auto_detects_active_desktop_user(self) -> None:
        script = BOOTSTRAP.read_text(encoding="utf-8")
        self.assertIn("active_desktop_user()", script)
        self.assertIn('loginctl show-session "$session" -p Type --value', script)
        self.assertIn('if [[ "$PLAYWRIGHT_HEADLESS" == false ]]; then', script)
        self.assertIn('PLAYWRIGHT_USER="$(active_desktop_user || true)"', script)
        self.assertIn('PLAYWRIGHT_USER="mcp-playwright"', script)


if __name__ == "__main__":
    unittest.main()
