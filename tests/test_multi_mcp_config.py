from __future__ import annotations

import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "multi_mcp_config.py"
spec = importlib.util.spec_from_file_location("multi_mcp_config", MODULE_PATH)
assert spec and spec.loader
multi = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = multi
spec.loader.exec_module(multi)


class MultiMcpConfigTests(unittest.TestCase):
    def test_each_connector_is_main_on_its_own_tunnel(self) -> None:
        profiles = {
            "serena": multi.render_profile(
                "tunnel_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", multi.serena_command("/opt/serena/bin/serena", Path("/workspace")), 18090
            ),
            "github": multi.render_profile(
                "tunnel_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", multi.github_command("/opt/github-mcp/github-mcp-server"), 18091
            ),
            "playwright": multi.render_profile(
                "tunnel_cccccccccccccccccccccccccccccccc",
                multi.playwright_command(
                    "/opt/node/bin/node",
                    "/opt/playwright/node_modules/@playwright/mcp/cli.js",
                    Path("/tmp/pw-out"),
                    "/opt/ms-playwright/chromium/chrome",
                ),
                18092,
            ),
        }
        for name, text in profiles.items():
            with self.subTest(name=name):
                self.assertEqual(text.count("channel: main"), 1)
                self.assertNotIn("channel: github", text)
                self.assertNotIn("channel: playwright", text)
        self.assertIn("tunnel_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", profiles["serena"])
        self.assertIn("tunnel_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", profiles["github"])
        self.assertIn("tunnel_cccccccccccccccccccccccccccccccc", profiles["playwright"])

    def test_secrets_are_scoped_per_connector(self) -> None:
        openai = "fixture-openai-key"
        github = "fixture-github-token"
        serena = multi.render_env("serena", openai, github_token=github)
        github_env = multi.render_env("github", openai, github_token=github)
        playwright = multi.render_env("playwright", openai, github_token=github, browsers_path="/tmp/browsers")
        self.assertIn(openai, serena)
        self.assertNotIn(github, serena)
        self.assertIn(github, github_env)
        self.assertNotIn("PLAYWRIGHT_BROWSERS_PATH", github_env)
        self.assertNotIn(github, playwright)
        self.assertIn("PLAYWRIGHT_BROWSERS_PATH=/tmp/browsers", playwright)

    def test_runtime_files_do_not_put_secrets_in_yaml(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            profile = root / "github.yaml"
            env_file = root / "github.env"
            old_cp = os.environ.get("CONTROL_PLANE_API_KEY")
            old_gh = os.environ.get("GITHUB_PERSONAL_ACCESS_TOKEN")
            try:
                os.environ["CONTROL_PLANE_API_KEY"] = "fixture-control-key"
                os.environ["GITHUB_PERSONAL_ACCESS_TOKEN"] = "fixture-github-token"
                multi.create_runtime(
                    profile,
                    env_file,
                    kind="github",
                    tunnel_id="tunnel_dddddddddddddddddddddddddddddddd",
                    command=multi.github_command("/opt/github-mcp/github-mcp-server"),
                    health_port=18091,
                )
            finally:
                if old_cp is None:
                    os.environ.pop("CONTROL_PLANE_API_KEY", None)
                else:
                    os.environ["CONTROL_PLANE_API_KEY"] = old_cp
                if old_gh is None:
                    os.environ.pop("GITHUB_PERSONAL_ACCESS_TOKEN", None)
                else:
                    os.environ["GITHUB_PERSONAL_ACCESS_TOKEN"] = old_gh
            yaml = profile.read_text(encoding="utf-8")
            env = env_file.read_text(encoding="utf-8")
            self.assertNotIn("fixture-control-key", yaml)
            self.assertNotIn("fixture-github-token", yaml)
            self.assertIn('api_key: "env:CONTROL_PLANE_API_KEY"', yaml)
            self.assertIn("fixture-control-key", env)
            self.assertIn("fixture-github-token", env)
            if os.name != "nt":
                self.assertEqual(profile.stat().st_mode & 0o777, 0o600)
                self.assertEqual(env_file.stat().st_mode & 0o777, 0o600)

    def test_linux_playwright_runs_browser_as_unprivileged_user(self) -> None:
        cmd = multi.playwright_command(
            "/opt/node/bin/node",
            "/opt/playwright/node_modules/@playwright/mcp/cli.js",
            Path("/opt/artifacts/playwright"),
            "/opt/ms-playwright/chromium-1243/chrome-linux64/chrome",
            run_as_user="kali",
            browsers_path="/opt/ms-playwright",
        )
        self.assertTrue(cmd.startswith("/usr/sbin/runuser -u kali -- /usr/bin/env -u CONTROL_PLANE_API_KEY "))
        self.assertIn("PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright", cmd)
        self.assertIn("--executable-path /opt/ms-playwright/chromium-1243/chrome-linux64/chrome", cmd)
        self.assertIn("--headless", cmd)
        self.assertNotIn("--no-sandbox", cmd)

    def test_linux_playwright_gui_inherits_desktop_session(self) -> None:
        cmd = multi.playwright_command(
            "/opt/node/bin/node",
            "/opt/playwright/node_modules/@playwright/mcp/cli.js",
            Path("/opt/artifacts/playwright"),
            "/opt/ms-playwright/chromium-1243/chrome-linux64/chrome",
            run_as_user="kali",
            browsers_path="/opt/ms-playwright",
            headless=False,
            desktop_env={
                "DISPLAY": ":0",
                "XAUTHORITY": "/home/kali/.Xauthority",
                "XDG_RUNTIME_DIR": "/run/user/1000",
                "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1000/bus",
            },
        )
        self.assertNotIn("--headless", cmd)
        self.assertIn("DISPLAY=:0", cmd)
        self.assertIn("XAUTHORITY=/home/kali/.Xauthority", cmd)
        self.assertIn("XDG_RUNTIME_DIR=/run/user/1000", cmd)
        self.assertIn("DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus", cmd)
        self.assertNotIn("CONTROL_PLANE_API_KEY=", cmd)
        self.assertNotIn("--no-sandbox", cmd)

    def test_windows_paths_are_safe_for_tunnel_parser(self) -> None:
        cmd = multi.playwright_command(
            r"C:\Program Files\nodejs\node.exe",
            r"C:\ProgramData\McpTunnelKit\playwright\cli.js",
            Path(r"C:\ProgramData\McpTunnelKit\artifacts\playwright"),
            r"C:\Program Files\Google\Chrome\Application\chrome.exe",
        )
        self.assertIn("'C:\\Program Files\\nodejs\\node.exe'", cmd)
        self.assertIn("'C:\\ProgramData\\McpTunnelKit\\playwright\\cli.js'", cmd)
        self.assertIn("--executable-path", cmd)
        self.assertIn("Google", cmd)
        self.assertNotIn("runuser", cmd)

    def test_github_requires_token(self) -> None:
        with self.assertRaises(ValueError):
            multi.render_env("github", "fixture-openai", github_token="")


if __name__ == "__main__":
    unittest.main()
