from __future__ import annotations

import importlib.util
import os
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "configure_runtime.py"
spec = importlib.util.spec_from_file_location("configure_runtime", MODULE_PATH)
assert spec and spec.loader
configure_runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(configure_runtime)


class ConfigureRuntimeTests(unittest.TestCase):
    def test_global_scalars_are_replaced(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "serena_config.yml"
            path.write_text(
                "language_backend: JetBrains\nlog_level: 20\ntool_timeout: 240\n"
                "default_max_tool_answer_chars: 150000\n",
                encoding="utf-8",
            )
            configure_runtime.configure_serena_global(path)
            text = path.read_text(encoding="utf-8")
            self.assertIn("language_backend: LSP", text)
            self.assertIn("log_level: 30", text)
            self.assertIn("tool_timeout: 90", text)
            self.assertIn("default_max_tool_answer_chars: 30000", text)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_tunnel_profile_gets_project_health_port_and_absolute_serena(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            profile = root / "chatgpt-mcp.yaml"
            project = root / "project"
            project.mkdir()
            profile.write_text(
                'health:\n  listen_addr: "127.0.0.1:8080"\n'
                'mcp:\n  commands:\n    - channel: main\n'
                '      command: "serena start-mcp-server --context chatgpt --language-backend LSP"\n',
                encoding="utf-8",
            )
            configure_runtime.configure_tunnel_profile(
                profile, project, 18090, serena_bin="/opt/serena/bin/serena"
            )
            text = profile.read_text(encoding="utf-8")
            self.assertIn('listen_addr: "127.0.0.1:18090"', text)
            self.assertIn(f"--project {project.resolve()}", text)
            self.assertIn("/opt/serena/bin/serena start-mcp-server", text)
            self.assertEqual(profile.stat().st_mode & 0o777, 0o600)

    def test_fresh_runtime_keeps_secret_out_of_profile_and_unit(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            profile = root / "config" / "chatgpt-mcp.yaml"
            env = root / "config" / "serena-tunnel.env"
            unit = root / "systemd" / "serena-tunnel.service"
            project = root / "project"
            tunnel_dir = root / "tunnel-client"
            project.mkdir()
            tunnel_dir.mkdir()
            secret = "sk-example-control-plane-secret"

            configure_runtime.create_fresh_runtime(
                profile,
                env,
                unit,
                project,
                "tunnel_abc123",
                secret,
                tunnel_dir,
                "/opt/serena/bin/serena",
                18090,
            )

            profile_text = profile.read_text(encoding="utf-8")
            unit_text = unit.read_text(encoding="utf-8")
            self.assertIn('tunnel_id: "tunnel_abc123"', profile_text)
            self.assertIn('api_key: "env:CONTROL_PLANE_API_KEY"', profile_text)
            self.assertNotIn(secret, profile_text)
            self.assertNotIn(secret, unit_text)
            self.assertIn(f"EnvironmentFile={env.resolve()}", unit_text)
            self.assertIn(f"WorkingDirectory={tunnel_dir.resolve()}", unit_text)
            self.assertIn("/opt/serena/bin/serena start-mcp-server", profile_text)
            self.assertEqual(env.read_text(encoding="utf-8"), f"CONTROL_PLANE_API_KEY={secret}\n")
            self.assertEqual(profile.stat().st_mode & 0o777, 0o600)
            self.assertEqual(env.stat().st_mode & 0o777, 0o600)
            self.assertEqual(unit.stat().st_mode & 0o777, 0o600)

    def test_fresh_runtime_rejects_bad_tunnel_id(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with self.assertRaises(ValueError):
                configure_runtime.create_fresh_runtime(
                    root / "profile.yml",
                    root / "env",
                    root / "unit",
                    root,
                    "not-a-tunnel-id",
                    "secret",
                    root,
                    "/bin/serena",
                    18090,
                )

    def test_systemd_secret_is_migrated_without_remaining_inline_value(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            unit = root / "serena-tunnel.service"
            env = root / "serena-tunnel.env"
            secret = "example-secret-value"
            unit.write_text(
                '[Service]\nEnvironment="CONTROL_PLANE_API_KEY=' + secret + '"\n'
                'ExecStart=/bin/true\n',
                encoding="utf-8",
            )
            migrated = configure_runtime.migrate_systemd_secret(unit, env)
            self.assertTrue(migrated)
            self.assertNotIn(secret, unit.read_text(encoding="utf-8"))
            self.assertIn(f"EnvironmentFile={env}", unit.read_text(encoding="utf-8"))
            self.assertEqual(env.read_text(encoding="utf-8"), f"CONTROL_PLANE_API_KEY={secret}\n")
            self.assertEqual(env.stat().st_mode & 0o777, 0o600)
            self.assertEqual(unit.stat().st_mode & 0o777, 0o600)

    def test_existing_environment_file_is_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            unit = root / "serena-tunnel.service"
            env = root / "serena-tunnel.env"
            env.write_text("CONTROL_PLANE_API_KEY=current\n", encoding="utf-8")
            os.chmod(env, 0o644)
            unit.write_text(f"[Service]\nEnvironmentFile={env}\n", encoding="utf-8")
            migrated = configure_runtime.migrate_systemd_secret(unit, env)
            self.assertFalse(migrated)
            self.assertEqual(env.stat().st_mode & 0o777, 0o600)

    def test_project_local_adds_generic_ignores_once(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "project.local.yml"
            path.write_text("# local overrides\n", encoding="utf-8")
            self.assertTrue(configure_runtime.configure_project_local(path))
            first = path.read_text(encoding="utf-8")
            self.assertIn("ignored_paths:", first)
            self.assertIn("**/node_modules/**", first)
            self.assertFalse(configure_runtime.configure_project_local(path))
            self.assertEqual(path.read_text(encoding="utf-8"), first)


if __name__ == "__main__":
    unittest.main()
