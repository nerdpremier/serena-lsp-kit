#!/usr/bin/env python3
"""Patch Serena 1.7.0 into an intentionally LSP-only installation.

The patch is deliberately small and idempotent:
- remove the unconditional JetBrains tool import from ``serena.tools``;
- make ``propagate_settings`` import the JetBrains plugin client directly;
- make the JetBrains backend fail clearly instead of requiring tool classes;
- remove ``jetbrains_tools.py`` after it has been backed up by the caller;
- cap ``execute_shell_command`` at 90 seconds and kill the spawned process group
  on timeout so child processes do not outlive the MCP request.

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


def _patch_cmd_tools(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    if "timeout=shell_timeout" in text:
        return False

    old = "        result = execute_shell_command(command, cwd=_cwd, capture_stderr=capture_stderr)\n"
    new = (
        "        shell_timeout = min(float(self.agent.serena_config.tool_timeout), 90.0)\n"
        "        result = execute_shell_command(\n"
        "            command,\n"
        "            cwd=_cwd,\n"
        "            capture_stderr=capture_stderr,\n"
        "            timeout=shell_timeout,\n"
        "        )\n"
    )
    if old not in text:
        raise RuntimeError("Could not find Serena 1.7.0 ExecuteShellCommandTool call")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    return True


def _patch_shell(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    original = text

    if "import signal\n" not in text:
        if "import os\n" not in text:
            raise RuntimeError("Could not find Serena 1.7.0 shell import block")
        text = text.replace("import os\n", "import os\nimport signal\n", 1)

    old_signature = (
        "def execute_shell_command(command: str, cwd: str | None = None, "
        "capture_stderr: bool = False) -> ShellCommandResult:\n"
    )
    new_signature = (
        "def execute_shell_command(\n"
        "    command: str,\n"
        "    cwd: str | None = None,\n"
        "    capture_stderr: bool = False,\n"
        "    timeout: float | None = None,\n"
        ") -> ShellCommandResult:\n"
    )
    if old_signature in text:
        text = text.replace(old_signature, new_signature, 1)
    elif "timeout: float | None = None" not in text:
        raise RuntimeError("Could not find Serena 1.7.0 execute_shell_command signature")

    if "start_new_session=os.name != \"nt\"" not in text:
        old_popen_tail = '        cwd=cwd,\n        **subprocess_kwargs(),\n'
        new_popen_tail = (
            '        cwd=cwd,\n'
            '        start_new_session=os.name != "nt",\n'
            '        **subprocess_kwargs(),\n'
        )
        if old_popen_tail not in text:
            raise RuntimeError("Could not find Serena 1.7.0 Popen argument block")
        text = text.replace(old_popen_tail, new_popen_tail, 1)

    old_communicate = (
        "    stdout, stderr = process.communicate()\n"
        "    return ShellCommandResult(stdout=stdout, stderr=stderr, "
        "return_code=process.returncode, cwd=cwd)\n"
    )
    new_communicate = (
        "    try:\n"
        "        stdout, stderr = process.communicate(timeout=timeout)\n"
        "        return_code = process.returncode\n"
        "    except subprocess.TimeoutExpired:\n"
        "        if os.name == \"nt\":\n"
        "            process.kill()\n"
        "        else:\n"
        "            os.killpg(process.pid, signal.SIGKILL)\n"
        "        stdout, stderr = process.communicate()\n"
        "        return_code = 124\n"
        "        if capture_stderr:\n"
        "            suffix = f\"Command timed out after {timeout:g} seconds.\"\n"
        "            stderr = f\"{stderr.rstrip()}\\n{suffix}\" if stderr else suffix\n"
        "    return ShellCommandResult(stdout=stdout, stderr=stderr, "
        "return_code=return_code, cwd=cwd)\n"
    )
    if old_communicate in text:
        text = text.replace(old_communicate, new_communicate, 1)
    elif "except subprocess.TimeoutExpired:" not in text:
        raise RuntimeError("Could not find Serena 1.7.0 communicate block")

    if text != original:
        path.write_text(text, encoding="utf-8")
        return True
    return False


def patch(package_root: Path) -> dict[str, bool]:
    package_root = package_root.resolve()
    tools_init = package_root / "tools" / "__init__.py"
    jetbrains_tools = package_root / "tools" / "jetbrains_tools.py"
    serena_config = package_root / "config" / "serena_config.py"
    cmd_tools = package_root / "tools" / "cmd_tools.py"
    shell = package_root / "util" / "shell.py"

    missing = [p for p in (tools_init, serena_config, cmd_tools, shell) if not p.is_file()]
    if missing:
        raise FileNotFoundError("Missing Serena files: " + ", ".join(map(str, missing)))

    result = {
        "tools_init_changed": _patch_tools_init(tools_init),
        "serena_config_changed": _patch_serena_config(serena_config),
        "cmd_tools_changed": _patch_cmd_tools(cmd_tools),
        "shell_changed": _patch_shell(shell),
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
