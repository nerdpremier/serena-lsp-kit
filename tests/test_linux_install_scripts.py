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
        script = UPDATE_PLAYWRIGHT.read_text(encoding="utf-8")
        self.assertIn(
            'PATH="$NODE_DIR/bin:$PATH" "$NODE_DIR/bin/npm" install',
            script,
        )
        self.assertIn('"$SCRIPT_DIR/update_node.sh"', script)

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
