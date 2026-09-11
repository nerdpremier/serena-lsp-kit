#!/usr/bin/env python3
"""Configure Serena/tunnel runtime files without exposing secrets."""

from __future__ import annotations

import argparse
import os
import re
import shlex
import tempfile
from pathlib import Path

DEFAULT_IGNORED_PATHS = (
    ".venv/**",
    "**/node_modules/**",
    ".scratch/**",
    "dist/**",
    "build/**",
    ".ruff_cache/**",
    ".mypy_cache/**",
    ".pytest_cache/**",
    ".git/**",
)


def _atomic_write(path: Path, text: str, mode: int | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    tmp = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        if mode is not None:
            os.chmod(tmp, mode)
        os.replace(tmp, path)
        if mode is not None:
            os.chmod(path, mode)
    finally:
        if tmp.exists():
            tmp.unlink()


def _replace_scalar(text: str, key: str, value: str) -> str:
    pattern = re.compile(rf"(?m)^{re.escape(key)}:\s*.*$")
    replacement = f"{key}: {value}"
    if pattern.search(text):
        return pattern.sub(replacement, text, count=1)
    suffix = "" if text.endswith("\n") else "\n"
    return text + suffix + replacement + "\n"


def configure_serena_global(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    text = _replace_scalar(text, "language_backend", "LSP")
    text = _replace_scalar(text, "log_level", "30")
    text = _replace_scalar(text, "tool_timeout", "90")
    text = _replace_scalar(text, "default_max_tool_answer_chars", "30000")
    _atomic_write(path, text, 0o600)


def configure_project_local(path: Path) -> bool:
    """Add a local ignore list when the project has not defined one already."""

    text = path.read_text(encoding="utf-8") if path.exists() else ""
    if re.search(r"(?m)^ignored_paths:\s*", text):
        return False
    if text and not text.endswith("\n"):
        text += "\n"
    text += "\n# Added by serena-lsp-kit to keep the LSP index focused.\nignored_paths:\n"
    text += "".join(f'- "{item}"\n' for item in DEFAULT_IGNORED_PATHS)
    _atomic_write(path, text, 0o600)
    return True


def configure_tunnel_profile(path: Path, project_path: Path, health_port: int) -> None:
    text = path.read_text(encoding="utf-8")
    quoted_project = shlex.quote(str(project_path.resolve()))
    command = (
        "serena start-mcp-server --context chatgpt --language-backend LSP "
        f"--project {quoted_project}"
    )

    listen_pattern = re.compile(r'(?m)^(\s*listen_addr:\s*)["\']?[^\n"\']+["\']?\s*$')
    if not listen_pattern.search(text):
        raise RuntimeError("Could not find health.listen_addr in tunnel profile")
    text = listen_pattern.sub(rf'\1"127.0.0.1:{health_port}"', text, count=1)

    command_pattern = re.compile(
        r'(?m)^(\s*-\s*channel:\s*main\s*\n\s*command:\s*)["\'].*?["\']\s*$'
    )
    if not command_pattern.search(text):
        command_pattern = re.compile(r'(?m)^(\s*command:\s*)["\'].*serena start-mcp-server.*["\']\s*$')
    if not command_pattern.search(text):
        raise RuntimeError("Could not find Serena MCP command in tunnel profile")
    text = command_pattern.sub(lambda m: f'{m.group(1)}"{command}"', text, count=1)
    _atomic_write(path, text, 0o600)


def migrate_systemd_secret(unit_path: Path, env_path: Path) -> bool:
    """Move an inline CONTROL_PLANE_API_KEY into a root-only EnvironmentFile."""

    text = unit_path.read_text(encoding="utf-8")
    inline = re.compile(
        r'(?m)^\s*Environment=["\']CONTROL_PLANE_API_KEY=(?P<value>[^"\'\n]+)["\']\s*$'
    )
    match = inline.search(text)
    env_directive = f"EnvironmentFile={env_path}"

    if match:
        value = match.group("value")
        _atomic_write(env_path, f"CONTROL_PLANE_API_KEY={value}\n", 0o600)
        text = inline.sub(env_directive, text, count=1)
        _atomic_write(unit_path, text, 0o600)
        return True

    if env_directive in text or re.search(r"(?m)^\s*EnvironmentFile=.*serena-tunnel\.env\s*$", text):
        if env_path.exists():
            os.chmod(env_path, 0o600)
        os.chmod(unit_path, 0o600)
        return False

    raise RuntimeError(
        "No inline CONTROL_PLANE_API_KEY or Serena tunnel EnvironmentFile found in systemd unit"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_global = sub.add_parser("serena-global")
    p_global.add_argument("path", type=Path)

    p_project = sub.add_parser("project-local")
    p_project.add_argument("path", type=Path)

    p_tunnel = sub.add_parser("tunnel-profile")
    p_tunnel.add_argument("path", type=Path)
    p_tunnel.add_argument("project", type=Path)
    p_tunnel.add_argument("--health-port", type=int, default=18090)

    p_unit = sub.add_parser("systemd-secret")
    p_unit.add_argument("unit", type=Path)
    p_unit.add_argument("env", type=Path)

    args = parser.parse_args()
    if args.cmd == "serena-global":
        configure_serena_global(args.path)
        print("serena_global=PASS")
    elif args.cmd == "project-local":
        changed = configure_project_local(args.path)
        print(f"project_local_changed={str(changed).lower()}")
    elif args.cmd == "tunnel-profile":
        configure_tunnel_profile(args.path, args.project, args.health_port)
        print("tunnel_profile=PASS")
    else:
        migrated = migrate_systemd_secret(args.unit, args.env)
        print(f"systemd_secret_migrated={str(migrated).lower()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
