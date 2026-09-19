# Serena LSP Kit — 4 Connector MCP Tunnel Bundle

Cross-platform installer for exposing four MCP servers to OpenAI as **four independent connectors**:

| Connector | Tunnel | MCP on `main` | Default health port |
|---|---|---|---:|
| Serena | Tunnel ID #1 | Serena 1.7.0, LSP-only | 18090 |
| GitHub | Tunnel ID #2 | GitHub MCP Server 1.12.1 | 18091 |
| Playwright | Tunnel ID #3 | Playwright MCP 0.0.80 | 18092 |
| Stitch | Tunnel ID #4 | Google Stitch MCP | 18093 |

This layout deliberately uses **one tunnel per MCP**. Each tunnel exposes only `channel: main`, so clients do not need multi-channel support and the four MCPs can appear as separate connectors.

## What you need

Create four OpenAI tunnel IDs. `tunnel-client 0.0.14` expects `tunnel_` followed by 32 lowercase letters/digits:

```text
SERENA_TUNNEL_ID=tunnel_...
GITHUB_TUNNEL_ID=tunnel_...
PLAYWRIGHT_TUNNEL_ID=tunnel_...
STITCH_TUNNEL_ID=tunnel_...
```

You can use the **same OpenAI Control Plane API key** for all installed tunnel processes:

```text
CONTROL_PLANE_API_KEY=...
```

GitHub additionally needs a PAT:

```text
GITHUB_PERSONAL_ACCESS_TOKEN=...
```

Playwright needs no additional API key. Stitch needs a Google Stitch API key:

```text
STITCH_API_KEY=...
```

Canonical OpenAI setup pages reported by tunnel-client:

- Tunnels: `https://platform.openai.com/settings/organization/tunnels`
- Runtime API keys: `https://platform.openai.com/settings/organization/api-keys`
- ChatGPT connector settings: `https://chatgpt.com/#settings/Connectors`

## Architecture

```text
ChatGPT / OpenAI
   |                 |                  |                  |
   v                 v                  v                  v
Serena tunnel     GitHub tunnel      Playwright tunnel    Stitch tunnel
   | main            | main             | main             | main
   v                 v                  v                  v
Serena MCP        GitHub MCP          Playwright MCP      Stitch MCP
   |                                      |                  |
   v                                      v                  v
Project source                         Chromium         Google Stitch
```

Secrets are scoped per connector. Serena, Playwright, and Stitch never receive the GitHub PAT; only Stitch receives `STITCH_API_KEY`.

## Linux

Requirements: Linux with systemd, Python 3.11–3.14, curl, unzip, sha256sum. Node.js/npm do not need to be installed system-wide; the kit installs and pins its own Node runtime for Playwright and Stitch.

```bash
 git clone https://github.com/nerdpremier/serena-lsp-kit.git
 cd serena-lsp-kit
 sudo ./bootstrap.sh /absolute/path/to/project
```

The installer securely prompts for:

1. Serena Tunnel ID
2. GitHub Tunnel ID
3. Playwright Tunnel ID
4. Stitch Tunnel ID
5. OpenAI Control Plane API key
6. GitHub PAT
7. Google Stitch API key

Non-interactive provisioning is also supported:

```bash
sudo env \
  SERENA_TUNNEL_ID=tunnel_... \
  GITHUB_TUNNEL_ID=tunnel_... \
  PLAYWRIGHT_TUNNEL_ID=tunnel_... \
  STITCH_TUNNEL_ID=tunnel_... \
  CONTROL_PLANE_API_KEY=... \
  GITHUB_PERSONAL_ACCESS_TOKEN=... \
  STITCH_API_KEY=... \
  ./bootstrap.sh /absolute/path/to/project
```

Linux creates these services:

```text
mcp-serena-tunnel.service
mcp-github-tunnel.service
mcp-playwright-tunnel.service
mcp-stitch-tunnel.service
```

and these isolated runtime files:

```text
/root/.config/tunnel-client/serena.yaml
/root/.config/tunnel-client/github.yaml
/root/.config/tunnel-client/playwright.yaml
/root/.config/tunnel-client/stitch.yaml

/root/.config/mcp-tunnel-kit/serena.env
/root/.config/mcp-tunnel-kit/github.env
/root/.config/mcp-tunnel-kit/playwright.env
/root/.config/mcp-tunnel-kit/stitch.env
```

Check all installed connectors:

```bash
mcp-stack-status
```

Rotate the shared OpenAI Control Plane key across all installed Linux connectors with automatic rollback if any tunnel fails health validation:

```bash
sudo rotate-mcp-control-plane-key
```

## Windows

Open **PowerShell as Administrator**:

```powershell
 git clone https://github.com/nerdpremier/serena-lsp-kit.git
 cd serena-lsp-kit
 powershell -NoProfile -ExecutionPolicy Bypass -File .\bootstrap.ps1 -ProjectPath 'C:\path\to\project'
```

Non-interactive example:

```powershell
$env:SERENA_TUNNEL_ID = 'tunnel_...'
$env:GITHUB_TUNNEL_ID = 'tunnel_...'
$env:PLAYWRIGHT_TUNNEL_ID = 'tunnel_...'
$env:STITCH_TUNNEL_ID = 'tunnel_...'
$env:CONTROL_PLANE_API_KEY = '...'
$env:GITHUB_PERSONAL_ACCESS_TOKEN = '...'
$env:STITCH_API_KEY = '...'
.\bootstrap.ps1 -ProjectPath 'C:\path\to\project'
```

Windows stores the runtime under:

```text
C:\ProgramData\McpTunnelKit
```

and creates four Scheduled Tasks:

```text
McpTunnelKit-Serena
McpTunnelKit-GitHub
McpTunnelKit-Playwright
McpTunnelKit-Stitch
```

Check all installed connectors:

```powershell
& 'C:\ProgramData\McpTunnelKit\scripts\Mcp-Stack-Status.ps1'
```

The Windows installer removes the old single-task `McpTunnelKit` layout when upgrading. For Playwright, it uses an existing Google Chrome Stable installation when available. If Chrome is missing, it installs `Google.Chrome` with `winget`; on x64 systems without `winget`, it falls back to Google's official Stable MSI after validating its Authenticode signature. ARM64 automatic installation requires `winget`.

## Optional connectors

You can intentionally omit GitHub, Playwright, or Stitch:

Linux:

```bash
sudo ./bootstrap.sh /path/to/project --skip-github
sudo ./bootstrap.sh /path/to/project --skip-playwright
sudo ./bootstrap.sh /path/to/project --skip-stitch
```

Windows:

```powershell
.\bootstrap.ps1 -ProjectPath 'C:\project' -SkipGitHub
.\bootstrap.ps1 -ProjectPath 'C:\project' -SkipPlaywright
.\bootstrap.ps1 -ProjectPath 'C:\project' -SkipStitch
```

Serena is always installed because it is the core project/code connector.

## Versions pinned by this kit

```text
Serena              1.7.0
OpenAI tunnel-client 0.0.14
GitHub MCP Server    1.12.1
Node.js              24.21.0
Playwright MCP       0.0.80
Google Stitch SDK    0.3.5
MCP JavaScript SDK   1.30.0
```

Upstream archives are verified against upstream checksum files before installation.

## Serena hardening

The installer keeps the Serena-specific stability changes used by this project:

- LSP backend only
- JetBrains MCP tool surface removed from the installed Serena runtime
- explicit project activation
- 90-second tool timeout
- 30,000-character default tool answer limit
- reduced logging
- generated/build/cache directories excluded from Serena indexing
- rollback backup before modifying an existing Linux Serena package

A new ChatGPT session may be required after Serena changes because clients can cache MCP tool schemas.

## GitHub security defaults

GitHub MCP runs with:

```text
GITHUB_LOCKDOWN_MODE=1
GITHUB_TOOLSETS=default,actions,code_security
```

Its PAT exists only in the GitHub connector environment file/process.

## Playwright security defaults

Playwright MCP runs:

```text
--headless
--isolated
--executable-path <browser executable>
```

Browser state is not kept as a persistent user profile. On Linux, the kit uses its managed Chromium build; the tunnel remains root-owned but the Playwright MCP/browser child is dropped to the invoking `sudo` user. For direct-root GUI installs, bootstrap uses the active desktop user; for direct-root headless installs (or when no desktop user can be found), it falls back to a dedicated `mcp-playwright` system user. This keeps Chromium sandboxing enabled. Set `MCP_PLAYWRIGHT_USER` to choose a different existing Linux runtime user. The Linux child also removes `CONTROL_PLANE_API_KEY` from its environment before starting Playwright.

Linux defaults to GUI/headed mode so you can see the real Chromium window while Playwright works. When bootstrap is launched directly as root, it now auto-detects the active X11/Wayland desktop user before falling back to the dedicated `mcp-playwright` account. It then detects `DISPLAY`/Wayland, `XAUTHORITY`, `XDG_RUNTIME_DIR`, and the desktop D-Bus address from that user's session. These can be overridden with `MCP_PLAYWRIGHT_DISPLAY`, `MCP_PLAYWRIGHT_WAYLAND_DISPLAY`, `MCP_PLAYWRIGHT_XAUTHORITY`, `MCP_PLAYWRIGHT_XDG_RUNTIME_DIR`, and `MCP_PLAYWRIGHT_DBUS_SESSION_BUS_ADDRESS`. For servers/CI or lower resource usage, explicitly enable headless mode:

```bash
sudo MCP_PLAYWRIGHT_HEADLESS=1 ./bootstrap.sh /absolute/path/to/project
```

On Windows, the kit uses Google Chrome Stable rather than the managed Chromium build. It reuses Chrome if already installed and installs Chrome automatically when missing. Playwright MCP output remains under the kit runtime directory.

## Stitch workflow and security

Stitch is an independent connector intended for UI design review before code changes. A typical workflow is:

```text
Requirement -> Stitch design -> human review -> Serena implementation -> Playwright validation
```

The connector exposes project/screen listing, asynchronous screen generation, job polling/results, and artifact pulling. Generated HTML/screenshots are written only inside the configured project workspace (under `stitch-output/` by default). Artifact downloads are restricted to Google user-content hosts and capped at 20 MiB per file.

`STITCH_API_KEY` exists only in the Stitch connector environment/process. Generation jobs persist in the Stitch runtime directory so a long-running generation can be polled after the initial tool call returns.

## Secret handling

Profiles contain references such as:

```yaml
api_key: "env:CONTROL_PLANE_API_KEY"
```

They do **not** contain the actual OpenAI key, GitHub PAT, or Stitch API key.

Linux secret files are root-only (`0600`). Windows config/secret files get explicit ACLs for the installing user, SYSTEM, and Administrators.

Do not commit real tunnel IDs, OpenAI keys, GitHub tokens, or Stitch API keys to this repository.

## Development

```bash
make test
```

CI validates Linux and Windows separately, including Python tests, ShellCheck, PowerShell parsing, and pinned upstream release assets.

## License

MIT. Serena, tunnel-client, GitHub MCP Server, Node.js, Playwright MCP, Chromium, Google Stitch SDK, and MCP SDK retain their respective upstream licenses.
