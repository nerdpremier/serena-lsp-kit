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


class PatchSerenaTests(unittest.TestCase):
    def make_tree(self, root: Path) -> Path:
        package = root / "serena"
        (package / "tools").mkdir(parents=True)
        (package / "config").mkdir(parents=True)
        (package / "tools" / "__init__.py").write_text(
            "from .tools_base import *\nfrom .jetbrains_tools import *\n", encoding="utf-8"
        )
        (package / "tools" / "jetbrains_tools.py").write_text("class X: pass\n", encoding="utf-8")
        (package / "config" / "serena_config.py").write_text(CONFIG_FIXTURE, encoding="utf-8")
        return package

    def test_patch_removes_jetbrains_tool_registration(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            package = self.make_tree(Path(tmp))
            result = patch_serena.patch(package)
            self.assertTrue(result["tools_init_changed"])
            self.assertTrue(result["serena_config_changed"])
            self.assertTrue(result["jetbrains_tools_removed"])

            tools_init = (package / "tools" / "__init__.py").read_text(encoding="utf-8")
            config = (package / "config" / "serena_config.py").read_text(encoding="utf-8")
            self.assertNotIn("jetbrains_tools", tools_init)
            self.assertFalse((package / "tools" / "jetbrains_tools.py").exists())
            self.assertIn("LSP-only Serena installation", config)
            self.assertIn("serena.jetbrains.jetbrains_plugin_client", config)
            self.assertNotIn("from serena.tools import JetBrainsPluginClient", config)

    def test_patch_is_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            package = self.make_tree(Path(tmp))
            patch_serena.patch(package)
            second = patch_serena.patch(package)
            self.assertFalse(second["tools_init_changed"])
            self.assertFalse(second["serena_config_changed"])
            self.assertFalse(second["jetbrains_tools_removed"])


if __name__ == "__main__":
    unittest.main()
