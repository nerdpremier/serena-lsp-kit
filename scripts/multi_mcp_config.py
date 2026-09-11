#!/usr/bin/env python3
"""Generate cross-platform tunnel-client profiles for Serena, GitHub and Playwright MCP."""

from __future__ import annotations

import argparse
import json
import os
import re
import tempfile
from dataclasses import dataclass
from pathlib import Path

GITHUB_TOOLSETS = "default,actions,code_security"


def _atomic_write(path: Path, text: str, mode: int | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    tmp = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
        if mode is not None:
            os.chmod(tmp, mode)
        os.replace(tmp, path)
        if mode is not None:
            os.chmod(path, mode)
    finally:
        if tmp.exists():
            tmp.unlink()


def validate_tunnel_id(value: str) -> None:
    if not re.fullmatch(r"tunnel_[A-Za-z0-9_-]+", value):
        raise ValueError("tunnel id must look like tunnel_...")


def validate_secret(name: str, value: str, *, required: bool = True) -> None:
    if required and not value:
        raise ValueError(f"{name} is required")
    if value and ("\n" in value or "\r" in value):
        raise ValueError(f"{name} must be a single line")


def quote_tunnel_arg(value: str) -> str:
    """Quote one argv item for tunnel-client's OS-independent command parser.

    tunnel-client treats backslash as an escape outside single quotes, so Windows
    paths must be single-quoted even if they contain no spaces.
    """

    if value and re.fullmatch(r"[A-Za-z0-9_./:@%+=,-]+", value):
        return value
    if "'" not in value:
        return "'" + value + "'"
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return '"' + escaped + '"'


def command_line(*args: str) -> str:
    return " ".join(quote_tunnel_arg(str(arg)) for arg in args)


def serena_command(serena_bin: str, project: Path) -> str:
    return command_line(
        serena_bin,
        "start-mcp-server",
        "--context",
        "chatgpt",
        "--language-backend",
        "LSP",
        "--project",
        str(project.resolve()),
    )


def github_command(github_bin: str) -> str:
    return command_line(github_bin, "stdio")


def playwright_command(node_bin: str, playwright_cli: str, output_dir: Path) -> str:
    return command_line(
        node_bin,
        playwright_cli,
        "--headless",
        "--isolated",
        "--output-dir",
        str(output_dir.resolve()),
    )


@dataclass(frozen=True)
class RuntimeSpec:
    project: Path
    tunnel_id: str
    serena_bin: str
    health_port: int = 18090
    github_bin: str | None = None
    node_bin: str | None = None
    playwright_cli: str | None = None
    playwright_output_dir: Path | None = None

    def commands(self) -> list[tuple[str, str]]:
        result = [("main", serena_command(self.serena_bin, self.project))]
        if self.github_bin:
            result.append(("github", github_command(self.github_bin)))
        if self.node_bin and self.playwright_cli:
            output = self.playwright_output_dir or self.project / ".mcp-artifacts" / "playwright"
            result.append(("playwright", playwright_command(self.node_bin, self.playwright_cli, output)))
        return result


def render_profile(spec: RuntimeSpec) -> str:
    validate_tunnel_id(spec.tunnel_id)
    commands = spec.commands()
    lines = [
        "config_version: 1",
        "control_plane:",
        '  base_url: "https://api.openai.com"',
        f"  tunnel_id: {json.dumps(spec.tunnel_id)}",
        '  api_key: "env:CONTROL_PLANE_API_KEY"',
        "health:",
        f'  listen_addr: "127.0.0.1:{spec.health_port}"',
        "admin_ui:",
        "  open_browser: false",
        "log:",
        "  level: info",
        "  format: json",
        "mcp:",
        "  commands:",
    ]
    for channel, command in commands:
        lines.extend(
            [
                f"    - channel: {channel}",
                f"      command: {json.dumps(command)}",
            ]
        )
    return "\n".join(lines) + "\n"


def render_env(control_plane_key: str, github_token: str = "") -> str:
    validate_secret("CONTROL_PLANE_API_KEY", control_plane_key)
    validate_secret("GITHUB_PERSONAL_ACCESS_TOKEN", github_token, required=False)
    lines = [f"CONTROL_PLANE_API_KEY={control_plane_key}"]
    if github_token:
        lines.extend(
            [
                f"GITHUB_PERSONAL_ACCESS_TOKEN={github_token}",
                f"GITHUB_TOOLSETS={GITHUB_TOOLSETS}",
                "GITHUB_LOCKDOWN_MODE=1",
            ]
        )
    return "\n".join(lines) + "\n"


def create_runtime_files(profile_path: Path, env_path: Path, spec: RuntimeSpec) -> None:
    control_key = os.environ.get("CONTROL_PLANE_API_KEY", "")
    github_token = os.environ.get("GITHUB_PERSONAL_ACCESS_TOKEN", "")
    if spec.github_bin and not github_token:
        raise ValueError("GITHUB_PERSONAL_ACCESS_TOKEN is required when GitHub MCP is enabled")
    _atomic_write(profile_path, render_profile(spec), 0o600)
    _atomic_write(env_path, render_env(control_key, github_token), 0o600)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("profile", type=Path)
    parser.add_argument("env", type=Path)
    parser.add_argument("project", type=Path)
    parser.add_argument("tunnel_id")
    parser.add_argument("--serena-bin", required=True)
    parser.add_argument("--health-port", type=int, default=18090)
    parser.add_argument("--github-bin")
    parser.add_argument("--node-bin")
    parser.add_argument("--playwright-cli")
    parser.add_argument("--playwright-output-dir", type=Path)
    args = parser.parse_args()

    spec = RuntimeSpec(
        project=args.project,
        tunnel_id=args.tunnel_id,
        serena_bin=args.serena_bin,
        health_port=args.health_port,
        github_bin=args.github_bin,
        node_bin=args.node_bin,
        playwright_cli=args.playwright_cli,
        playwright_output_dir=args.playwright_output_dir,
    )
    create_runtime_files(args.profile, args.env, spec)
    print("multi_mcp_runtime=PASS")
    print("channels=" + ",".join(channel for channel, _ in spec.commands()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
