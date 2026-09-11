#!/usr/bin/env python3
"""Patch Serena 1.7.0 into an intentionally LSP-only installation.

The patch is deliberately small and idempotent:
- remove the unconditional JetBrains tool import from ``serena.tools``;
- make ``propagate_settings`` import the JetBrains plugin client directly;
- make the JetBrains backend fail clearly instead of requiring tool classes;
- remove ``jetbrains_tools.py`` after it has been backed up by the caller.

This module never touches credentials or systemd state.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path

JETBRAINS_IMPORT = "from .jetbrains_tools import *"
DIRECT_CLIENT_IMPORT = (
    "        from serena.jetbrains.jetbrains_plugin_client import JetBrainsPluginClient"
)
OLD_CLIENT_IMPORT = "        from serena.tools import JetBrainsPluginClient"
DISABLED_MESSAGE = "JetBrains backend support is disabled in this LSP-only Serena installation"


def _patch_tools_init(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    filtered = [line for line in lines if line.strip() != JETBRAINS_IMPORT]
    new_text = "\n".join(filtered) + ("\n" if text.endswith("\n") else "")
    if new_text == text:
        return False
    path.write_text(new_text, encoding="utf-8")
    return True


def _patch_serena_config(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    original = text

    if OLD_CLIENT_IMPORT in text:
        text = text.replace(OLD_CLIENT_IMPORT, DIRECT_CLIENT_IMPORT, 1)

    if DISABLED_MESSAGE not in text:
        block = re.compile(
            r"(?ms)^(?P<indent>\s{12})case LanguageBackend\.JETBRAINS:\n"
            r".*?"
            r"^(?P=indent)case _:\n"
        )
        replacement = (
            "            case LanguageBackend.JETBRAINS:\n"
            "                raise RuntimeError(\n"
            f"                    {DISABLED_MESSAGE!r}\n"
            "                )\n"
            "            case _:\n"
        )
        text, count = block.subn(replacement, text, count=1)
        if count != 1:
            raise RuntimeError(
                "Could not find Serena 1.7.0 LanguageBackend.JETBRAINS replacement block"
            )

    if text != original:
        path.write_text(text, encoding="utf-8")
        return True
    return False


def patch(package_root: Path) -> dict[str, bool]:
    package_root = package_root.resolve()
    tools_init = package_root / "tools" / "__init__.py"
    jetbrains_tools = package_root / "tools" / "jetbrains_tools.py"
    serena_config = package_root / "config" / "serena_config.py"

    missing = [p for p in (tools_init, serena_config) if not p.is_file()]
    if missing:
        raise FileNotFoundError("Missing Serena files: " + ", ".join(map(str, missing)))

    result = {
        "tools_init_changed": _patch_tools_init(tools_init),
        "serena_config_changed": _patch_serena_config(serena_config),
        "jetbrains_tools_removed": False,
    }
    if jetbrains_tools.exists():
        jetbrains_tools.unlink()
        result["jetbrains_tools_removed"] = True
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("package_root", type=Path)
    args = parser.parse_args()
    result = patch(args.package_root)
    for key, value in result.items():
        print(f"{key}={str(value).lower()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
