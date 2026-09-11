#!/usr/bin/env python3
"""Generate isolated tunnel-client profiles for Serena, GitHub and Playwright MCP."""

from __future__ import annotations

import argparse
import json
import os
import re
import tempfile
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
    if not re.fullmatch(r"tunnel_[a-z0-9]{32}", value):
        raise ValueError("tunnel id must look like tunnel_...")


def validate_secret(name: str, value: str) -> None:
    if not value:
        raise ValueError(f"{name} is required")
    if "\n" in value or "\r" in value:
        raise ValueError(f"{name} must be a single line")


def quote_tunnel_arg(value: str) -> str:
    """Quote one argv item for tunnel-client's OS-independent command parser."""
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


def playwright_command(
    node_bin: str,
    playwright_cli: str,
    output_dir: Path,
    executable_path: str = "",
    *,
    run_as_user: str = "",
    browsers_path: str = "",
    headless: bool = True,
    desktop_env: dict[str, str] | None = None,
) -> str:
    args = [node_bin, playwright_cli]
    if headless:
        args.append("--headless")
    args.append("--isolated")
    if executable_path:
        args.extend(["--executable-path", executable_path])
    args.extend(["--output-dir", str(output_dir.resolve())])
    if run_as_user:
        prefix = [
            "/usr/sbin/runuser",
            "-u",
            run_as_user,
            "--",
            "/usr/bin/env",
            "-u",
            "CONTROL_PLANE_API_KEY",
        ]
        if browsers_path:
            prefix.append(f"PLAYWRIGHT_BROWSERS_PATH={browsers_path}")
        for key in (
            "DISPLAY",
            "WAYLAND_DISPLAY",
            "XAUTHORITY",
            "XDG_RUNTIME_DIR",
            "DBUS_SESSION_BUS_ADDRESS",
        ):
            value = (desktop_env or {}).get(key, "")
            if value:
                prefix.append(f"{key}={value}")
        args = prefix + args
    return command_line(*args)


def render_profile(tunnel_id: str, command: str, health_port: int) -> str:
    """Render one tunnel/one connector. Every connector is exposed as channel main."""
    validate_tunnel_id(tunnel_id)
    return "\n".join(
        [
            "config_version: 1",
            "control_plane:",
            '  base_url: "https://api.openai.com"',
            f"  tunnel_id: {json.dumps(tunnel_id)}",
            '  api_key: "env:CONTROL_PLANE_API_KEY"',
            "health:",
            f'  listen_addr: "127.0.0.1:{health_port}"',
            "admin_ui:",
            "  open_browser: false",
            "log:",
            "  level: info",
            "  format: json",
            "mcp:",
            "  commands:",
            "    - channel: main",
            f"      command: {json.dumps(command)}",
            "",
        ]
    )


def render_env(kind: str, control_plane_key: str, *, github_token: str = "", browsers_path: str = "") -> str:
    validate_secret("CONTROL_PLANE_API_KEY", control_plane_key)
    lines = [f"CONTROL_PLANE_API_KEY={control_plane_key}"]
    if kind == "github":
        validate_secret("GITHUB_PERSONAL_ACCESS_TOKEN", github_token)
        lines.extend(
            [
                f"GITHUB_PERSONAL_ACCESS_TOKEN={github_token}",
                f"GITHUB_TOOLSETS={GITHUB_TOOLSETS}",
                "GITHUB_LOCKDOWN_MODE=1",
            ]
        )
    elif kind == "playwright" and browsers_path:
        validate_secret("PLAYWRIGHT_BROWSERS_PATH", browsers_path)
        lines.append(f"PLAYWRIGHT_BROWSERS_PATH={browsers_path}")
    elif kind not in {"serena", "playwright"}:
        raise ValueError(f"unsupported runtime kind: {kind}")
    return "\n".join(lines) + "\n"


def create_runtime(profile: Path, env_file: Path, *, kind: str, tunnel_id: str, command: str, health_port: int, browsers_path: str = "") -> None:
    control_key = os.environ.get("CONTROL_PLANE_API_KEY", "")
    github_token = os.environ.get("GITHUB_PERSONAL_ACCESS_TOKEN", "")
    _atomic_write(profile, render_profile(tunnel_id, command, health_port), 0o600)
    _atomic_write(
        env_file,
        render_env(kind, control_key, github_token=github_token, browsers_path=browsers_path),
        0o600,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate one-tunnel-per-MCP profiles")
    sub = parser.add_subparsers(dest="kind", required=True)

    def common(p: argparse.ArgumentParser) -> None:
        p.add_argument("profile", type=Path)
        p.add_argument("env", type=Path)
        p.add_argument("tunnel_id")
        p.add_argument("--health-port", type=int, required=True)

    p_serena = sub.add_parser("serena")
    common(p_serena)
    p_serena.add_argument("project", type=Path)
    p_serena.add_argument("--serena-bin", required=True)

    p_github = sub.add_parser("github")
    common(p_github)
    p_github.add_argument("--github-bin", required=True)

    p_playwright = sub.add_parser("playwright")
    common(p_playwright)
    p_playwright.add_argument("--node-bin", required=True)
    p_playwright.add_argument("--playwright-cli", required=True)
    p_playwright.add_argument("--output-dir", type=Path, required=True)
    p_playwright.add_argument("--browsers-path", required=True)
    p_playwright.add_argument("--browser-executable", required=True)
    p_playwright.add_argument("--run-as-user", default="")
    p_playwright.add_argument("--headed", action="store_true")
    p_playwright.add_argument("--display", default="")
    p_playwright.add_argument("--wayland-display", default="")
    p_playwright.add_argument("--xauthority", default="")
    p_playwright.add_argument("--xdg-runtime-dir", default="")
    p_playwright.add_argument("--dbus-session-bus-address", default="")

    args = parser.parse_args()
    if args.kind == "serena":
        command = serena_command(args.serena_bin, args.project)
        browsers_path = ""
    elif args.kind == "github":
        command = github_command(args.github_bin)
        browsers_path = ""
    else:
        command = playwright_command(
            args.node_bin,
            args.playwright_cli,
            args.output_dir,
            args.browser_executable,
            run_as_user=args.run_as_user,
            browsers_path=args.browsers_path,
            headless=not args.headed,
            desktop_env={
                "DISPLAY": args.display,
                "WAYLAND_DISPLAY": args.wayland_display,
                "XAUTHORITY": args.xauthority,
                "XDG_RUNTIME_DIR": args.xdg_runtime_dir,
                "DBUS_SESSION_BUS_ADDRESS": args.dbus_session_bus_address,
            },
        )
        browsers_path = args.browsers_path

    create_runtime(
        args.profile,
        args.env,
        kind=args.kind,
        tunnel_id=args.tunnel_id,
        command=command,
        health_port=args.health_port,
        browsers_path=browsers_path,
    )
    print(f"runtime={args.kind}")
    print("channel=main")
    print("profile=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
