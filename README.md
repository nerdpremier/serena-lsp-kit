# Serena LSP Kit — MCP Tunnel Bundle

Cross-platform installer for an OpenAI Secure MCP Tunnel with three local MCP servers:

| Channel | MCP server | Purpose |
| --- | --- | --- |
| `main` | Serena `1.7.0` | code intelligence, symbols, refactoring |
| `github` | GitHub MCP Server `1.12.1` | repositories, issues, PRs, Actions, code security |
| `playwright` | Playwright MCP `0.0.80` | browser automation and web testing |

The kit supports **Linux (systemd)** and **Windows 10/11**. The same tunnel-client process can route requests to multiple logical MCP channels.

## Pinned runtime

- OpenAI `tunnel-client` `0.0.14`
- Serena `1.7.0`, patched LSP-only
- GitHub MCP Server `1.12.1` native binary
- Node.js `24.21.0` LTS
- Playwright MCP `0.0.80`

Downloaded release artifacts are checked against their upstream SHA256 files before installation.

## Credentials

You need these values:

1. **OpenAI Tunnel ID** — `tunnel_...`
2. **OpenAI Control Plane API key** — a runtime key with tunnel Read + Use permission
3. **GitHub Personal Access Token** — required only when the GitHub MCP channel is enabled

The OpenAI runtime key and GitHub token are never written into the tunnel YAML and must never be committed to Git.

For GitHub, prefer a fine-grained PAT limited to only the repositories and permissions you actually need. The GitHub MCP server is configured with lockdown mode enabled by default.

## Linux install

Prerequisites: Linux with systemd, root access, Python 3 with `venv`, `curl`, `unzip`, `tar`, and `sha256sum`.

```bash
git clone https://github.com/nerdpremier/serena-lsp-kit.git
cd serena-lsp-kit
sudo ./bootstrap.sh /absolute/path/to/project
```

The installer prompts for Tunnel ID, OpenAI runtime key, and GitHub PAT. Secret input is hidden.

Non-interactive provisioning is also supported:

```bash
sudo env \
  MCP_TUNNEL_ID='tunnel_...' \
  CONTROL_PLANE_API_KEY='...' \
  GITHUB_PERSONAL_ACCESS_TOKEN='...' \
  ./bootstrap.sh /absolute/path/to/project
```

Optional channels can be disabled:

```bash
sudo ./bootstrap.sh /path/to/project --skip-github
sudo ./bootstrap.sh /path/to/project --skip-playwright
```

Linux runtime files are kept under `/opt/serena-lsp-kit`, `/root/.config/tunnel-client`, and the existing compatibility service name `serena-tunnel.service`.

Check status:

```bash
mcp-stack-status
```

## Windows install

Open **PowerShell as Administrator**:

```powershell
git clone https://github.com/nerdpremier/serena-lsp-kit.git
Set-Location .\serena-lsp-kit
powershell -NoProfile -ExecutionPolicy Bypass -File .\bootstrap.ps1 -ProjectPath 'C:\path\to\project'
```

The Windows installer:

- installs `uv` when needed using Astral's official installer;
- creates an isolated Serena environment under `C:\ProgramData\McpTunnelKit`;
- downloads verified Windows builds of tunnel-client and GitHub MCP;
- downloads a verified portable Node.js build and installs Playwright MCP + Chromium;
- creates the same three MCP channels as Linux;
- stores secrets in `C:\ProgramData\McpTunnelKit\config\secrets.env` with restricted ACLs;
- registers a `McpTunnelKit` Scheduled Task that starts at user logon;
- runs `tunnel-client doctor` and local health/readiness checks.

Non-interactive values can be supplied as environment variables before running `bootstrap.ps1`:

```powershell
$env:MCP_TUNNEL_ID = 'tunnel_...'
$env:CONTROL_PLANE_API_KEY = '...'
$env:GITHUB_PERSONAL_ACCESS_TOKEN = '...'
.\bootstrap.ps1 -ProjectPath 'C:\path\to\project'
```

Check Windows status:

```powershell
& 'C:\ProgramData\McpTunnelKit\scripts\Mcp-Stack-Status.ps1'
```

## How routing works

`tunnel-client` requires a `main` channel and supports additional channel-qualified MCP bindings. This kit uses:

```text
OpenAI Tunnel
├── main        -> Serena
├── github      -> GitHub MCP Server
└── playwright  -> Playwright MCP
```

The caller must send the matching logical channel for `github` or `playwright`. Clients that only ever address the default `main` channel will see Serena only; in that case use separate tunnel/profile instances for the other MCP servers.

## Serena hardening

The Serena installation is deliberately LSP-only:

- explicit project path at startup;
- JetBrains-specific tools removed from the runtime registry;
- global language backend forced to LSP;
- tool timeout reduced to 90 seconds;
- maximum tool response reduced to 30,000 characters;
- noisy project/cache paths ignored;
- warning/error logging by default.

A client that cached old MCP schemas may need a new chat/client session after installation.

## GitHub MCP defaults

GitHub MCP receives its PAT through `GITHUB_PERSONAL_ACCESS_TOKEN` and is started with these environment defaults:

```text
GITHUB_TOOLSETS=default,actions,code_security
GITHUB_LOCKDOWN_MODE=1
```

The token is not part of the YAML command line.

## Playwright defaults

Playwright MCP runs:

- headless;
- isolated browser profile;
- with a dedicated Chromium installation;
- with output artifacts under the kit data directory.

No Playwright credential is required by the installer. Website credentials remain the responsibility of the browser session/application being tested.

## Linux upgrade path

Existing Linux Serena-only installations can continue using:

```bash
sudo ./install.sh /absolute/path/to/project --restart
```

`bootstrap.sh` is the recommended command for a fresh multi-MCP installation.

## Rollback

The legacy Linux Serena patch keeps backups under:

```text
/root/.serena/lsp-only-kit-backups/
```

Restore the most recent Serena package/config backup with:

```bash
sudo ./rollback.sh --restart
```

Rollback intentionally does not put API keys back into a systemd unit.

## Development

```bash
make test
```

CI validates Linux and Windows separately. Linux runs Python tests, Bash syntax, and ShellCheck. Windows validates the shared profile generator and parses all PowerShell installers using the PowerShell AST parser.

## Security notes

- No real Tunnel ID, OpenAI key, or GitHub token belongs in this repository.
- The tunnel profile stores `api_key: env:CONTROL_PLANE_API_KEY`, never the literal runtime key.
- Linux secrets use root-only mode `0600`.
- Windows secrets use a protected ACL for the installing user, SYSTEM, and Administrators only.
- Playwright is headless and isolated by default.
- GitHub lockdown mode is enabled by default; use a least-privilege PAT.
- All downloaded pinned release archives are SHA256 verified against upstream checksum files.

## Upstream projects

- OpenAI tunnel-client: https://github.com/openai/tunnel-client
- Serena: https://github.com/oraios/serena
- GitHub MCP Server: https://github.com/github/github-mcp-server
- Playwright MCP: https://github.com/microsoft/playwright-mcp
- Node.js: https://nodejs.org/

## License

MIT. This repository contains only installation/configuration glue. Each upstream dependency retains its own license.
