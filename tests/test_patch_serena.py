from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "patch_serena.py"
spec = importlib.util.spec_from_file_location("patch_serena", MODULE_PATH)
assert spec and spec.loader
patch_serena = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patch_serena)

CONFIG_FIXTURE = '''from enum import Enum

class LanguageBackend(Enum):
    LSP = "LSP"
    JETBRAINS = "JetBrains"

    def get_lsp_tool_class_replacements(self):
        match self:
            case LanguageBackend.LSP:
                return {}
            case LanguageBackend.JETBRAINS:
                from ..tools import jetbrains_tools, symbol_tools

                return {
                    symbol_tools.FindSymbolTool: jetbrains_tools.JetBrainsFindSymbolTool,
                    symbol_tools.GetSymbolsOverviewTool: jetbrains_tools.JetBrainsGetSymbolsOverviewTool,
                    symbol_tools.FindReferencingSymbolsTool: jetbrains_tools.JetBrainsFindReferencingSymbolsTool,
                    symbol_tools.FindImplementationsTool: jetbrains_tools.JetBrainsFindImplementationsTool,
                    symbol_tools.FindDeclarationTool: jetbrains_tools.JetBrainsFindDeclarationTool,
                    symbol_tools.RenameSymbolTool: jetbrains_tools.JetBrainsRenameTool,
                    symbol_tools.SafeDeleteSymbol: jetbrains_tools.JetBrainsSafeDeleteTool,
                }
            case _:
                raise NotImplementedError()

class SerenaConfig:
    def propagate_settings(self):
        from serena.tools import JetBrainsPluginClient
        JetBrainsPluginClient.set_server_address("127.0.0.1")
'''

CMD_TOOLS_FIXTURE = '''from serena.util.shell import execute_shell_command

class ExecuteShellCommandTool:
    def apply(self, command, cwd=None, capture_stderr=True):
        _cwd = cwd
        result = execute_shell_command(command, cwd=_cwd, capture_stderr=capture_stderr)
        result = result.model_dump_json()
        return result
'''

SHELL_FIXTURE = '''import os
import subprocess

from pydantic import BaseModel

class ShellCommandResult(BaseModel):
    stdout: str
    return_code: int
    cwd: str | None = None
    stderr: str | None = None

def subprocess_kwargs():
    return {}

def execute_shell_command(command: str, cwd: str | None = None, capture_stderr: bool = False) -> ShellCommandResult:
    process = subprocess.Popen(
        command,
        shell=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE if capture_stderr else None,
        text=True,
        encoding="utf-8",
        errors="replace",
        cwd=cwd,
        **subprocess_kwargs(),
    )

    stdout, stderr = process.communicate()
    return ShellCommandResult(stdout=stdout, stderr=stderr, return_code=process.returncode, cwd=cwd)
'''


class PatchSerenaTests(unittest.TestCase):
    def make_tree(self, root: Path) -> Path:
        package = root / "serena"
        (package / "tools").mkdir(parents=True)
        (package / "config").mkdir(parents=True)
        (package / "util").mkdir(parents=True)
        (package / "tools" / "__init__.py").write_text(
            "from .tools_base import *\nfrom .jetbrains_tools import *\n", encoding="utf-8"
        )
        (package / "tools" / "jetbrains_tools.py").write_text("class X: pass\n", encoding="utf-8")
        (package / "config" / "serena_config.py").write_text(CONFIG_FIXTURE, encoding="utf-8")
        (package / "tools" / "cmd_tools.py").write_text(CMD_TOOLS_FIXTURE, encoding="utf-8")
        (package / "util" / "shell.py").write_text(SHELL_FIXTURE, encoding="utf-8")
        return package

    def test_patch_applies_lsp_only_and_timeout_hardening(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            package = self.make_tree(Path(tmp))
            result = patch_serena.patch(package)
            self.assertTrue(result["tools_init_changed"])
            self.assertTrue(result["serena_config_changed"])
            self.assertTrue(result["cmd_tools_changed"])
            self.assertTrue(result["shell_changed"])
            self.assertTrue(result["jetbrains_tools_removed"])

            tools_init = (package / "tools" / "__init__.py").read_text(encoding="utf-8")
            config = (package / "config" / "serena_config.py").read_text(encoding="utf-8")
            cmd_tools = (package / "tools" / "cmd_tools.py").read_text(encoding="utf-8")
            shell = (package / "util" / "shell.py").read_text(encoding="utf-8")

            self.assertNotIn("jetbrains_tools", tools_init)
            self.assertFalse((package / "tools" / "jetbrains_tools.py").exists())
            self.assertIn("LSP-only Serena installation", config)
            self.assertIn("serena.jetbrains.jetbrains_plugin_client", config)
            self.assertIn("min(float(self.agent.serena_config.tool_timeout), 90.0)", cmd_tools)
            self.assertIn("timeout=shell_timeout", cmd_tools)
            self.assertIn("timeout: float | None = None", shell)
            self.assertIn('start_new_session=os.name != "nt"', shell)
            self.assertIn("except subprocess.TimeoutExpired:", shell)
            self.assertIn("os.killpg(process.pid, signal.SIGKILL)", shell)
            self.assertIn("return_code = 124", shell)

    def test_patch_is_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            package = self.make_tree(Path(tmp))
            patch_serena.patch(package)
            second = patch_serena.patch(package)
            self.assertFalse(second["tools_init_changed"])
            self.assertFalse(second["serena_config_changed"])
            self.assertFalse(second["cmd_tools_changed"])
            self.assertFalse(second["shell_changed"])
            self.assertFalse(second["jetbrains_tools_removed"])


if __name__ == "__main__":
    unittest.main()
