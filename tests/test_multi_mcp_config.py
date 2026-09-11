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
    def test_linux_profile_has_three_channels_and_no_secrets(self) -> None:
        root = Path("/opt/mcp-kit")
        runtime = multi.RuntimeSpec(
            project=Path("/srv/project"),
            tunnel_id="tunnel_abc123",
            serena_bin="/opt/mcp-kit/serena/bin/serena",
            github_bin="/opt/mcp-kit/bin/github-mcp-server",
            node_bin="/opt/mcp-kit/node/bin/node",
            playwright_cli="/opt/mcp-kit/playwright/node_modules/@playwright/mcp/cli.js",
            playwright_output_dir=root / "artifacts/playwright",
        )
        text = multi.render_profile(runtime)
        self.assertIn("channel: main", text)
        self.assertIn("channel: github", text)
        self.assertIn("channel: playwright", text)
        self.assertIn("github-mcp-server", text)
        self.assertIn("--headless", text)
        self.assertNotIn("cp-secret", text)
        self.assertNotIn("gh-secret", text)

    def test_windows_paths_are_single_quoted_for_tunnel_parser(self) -> None:
        cmd = multi.command_line(
            r"C:\Program Files\nodejs\node.exe",
            r"C:\ProgramData\McpTunnelKit\playwright\cli.js",
            "--headless",
        )
        self.assertIn("'C:\\Program Files\\nodejs\\node.exe'", cmd)
        self.assertIn("'C:\\ProgramData\\McpTunnelKit\\playwright\\cli.js'", cmd)

    def test_env_keeps_github_and_openai_secrets_out_of_profile(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            profile = root / "profile.yaml"
            env_file = root / "secrets.env"
            runtime = multi.RuntimeSpec(
                project=root / "project",
                tunnel_id="tunnel_test123",
                serena_bin="/bin/serena",
                github_bin="/bin/github-mcp-server",
            )
            (root / "project").mkdir()
            old_cp = os.environ.get("CONTROL_PLANE_API_KEY")
            old_gh = os.environ.get("GITHUB_PERSONAL_ACCESS_TOKEN")
            try:
                os.environ["CONTROL_PLANE_API_KEY"] = "cp-secret-value"
                os.environ["GITHUB_PERSONAL_ACCESS_TOKEN"] = "gh-secret-value"
                multi.create_runtime_files(profile, env_file, runtime)
            finally:
                if old_cp is None:
                    os.environ.pop("CONTROL_PLANE_API_KEY", None)
                else:
                    os.environ["CONTROL_PLANE_API_KEY"] = old_cp
                if old_gh is None:
                    os.environ.pop("GITHUB_PERSONAL_ACCESS_TOKEN", None)
                else:
                    os.environ["GITHUB_PERSONAL_ACCESS_TOKEN"] = old_gh
            profile_text = profile.read_text(encoding="utf-8")
            env_text = env_file.read_text(encoding="utf-8")
            self.assertNotIn("cp-secret-value", profile_text)
            self.assertNotIn("gh-secret-value", profile_text)
            self.assertIn("CONTROL_PLANE_API_KEY=cp-secret-value", env_text)
            self.assertIn("GITHUB_PERSONAL_ACCESS_TOKEN=gh-secret-value", env_text)
            self.assertIn("GITHUB_LOCKDOWN_MODE=1", env_text)

    def test_github_channel_requires_token(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            runtime = multi.RuntimeSpec(
                project=root,
                tunnel_id="tunnel_test123",
                serena_bin="serena",
                github_bin="github-mcp-server",
            )
            old_cp = os.environ.get("CONTROL_PLANE_API_KEY")
            old_gh = os.environ.pop("GITHUB_PERSONAL_ACCESS_TOKEN", None)
            try:
                os.environ["CONTROL_PLANE_API_KEY"] = "cp-secret"
                with self.assertRaisesRegex(ValueError, "GITHUB_PERSONAL_ACCESS_TOKEN"):
                    multi.create_runtime_files(root / "profile", root / "env", runtime)
            finally:
                if old_cp is None:
                    os.environ.pop("CONTROL_PLANE_API_KEY", None)
                else:
                    os.environ["CONTROL_PLANE_API_KEY"] = old_cp
                if old_gh is not None:
                    os.environ["GITHUB_PERSONAL_ACCESS_TOKEN"] = old_gh


if __name__ == "__main__":
    unittest.main()
