# serena-lsp-kit

Cross-platform installer for exposing two MCP servers to OpenAI as **two independent connectors**:

| Connector | Tunnel | MCP on `main` | Default health port |
|---|---|---|---:|
| Serena | Tunnel ID #1 | Serena 1.7.0, LSP-only | 18090 |
| Playwright | Tunnel ID #2 | Playwright MCP 0.0.80 | 18092 |

Each MCP gets its own tunnel and exposes only `channel: main`.

GitHub access is intentionally outside this kit. Use ChatGPT's official GitHub connector separately if needed.

## What you need

Create two OpenAI tunnel IDs. `tunnel-client 0.0.14` expects `tunnel_` followed by 32 lowercase letters/digits:

```text
SERENA_TUNNEL_ID=tunnel_...
PLAYWRIGHT_TUNNEL_ID=tunnel_...
```

The installed tunnel processes can share one OpenAI Control Plane API key:

```text
CONTROL_PLANE_API_KEY=...
```

Playwright needs no additional API key.

Canonical OpenAI setup pages reported by tunnel-client:

- Tunnels: `https://platform.openai.com/settings/organization/tunnels`
- Runtime API keys: `https://platform.openai.com/settings/organization/api-keys`
- ChatGPT connector settings: `https://chatgpt.com/#settings/Connectors`

## Architecture

```text
ChatGPT / OpenAI
   |                 |
   v                 v
Serena tunnel     Playwright tunnel
   | main            | main
   v                 v
Serena MCP        Playwright MCP
   |                 |
   v                 v
Project source     Chromium
```

## Linux

Requirements: Linux with systemd, Python 3.11–3.14, curl, unzip, and sha256sum. Node.js/npm do not need to be installed system-wide; the kit installs and pins its own Node runtime for Playwright.

```bash
git clone https://github.com/nerdpremier/serena-lsp-kit.git
cd serena-lsp-kit
sudo ./bootstrap.sh /absolute/path/to/project
```

The installer prompts for:

1. Serena Tunnel ID
2. Playwright Tunnel ID
3. OpenAI Control Plane API key

Non-interactive provisioning:

```bash
sudo env \
  SERENA_TUNNEL_ID=tunnel_... \
  PLAYWRIGHT_TUNNEL_ID=tunnel_... \
  CONTROL_PLANE_API_KEY=... \
  ./bootstrap.sh /absolute/path/to/project
```

Linux creates:

```text
mcp-serena-tunnel.service
mcp-playwright-tunnel.service
```

Runtime files:

```text
/root/.config/tunnel-client/serena.yaml
/root/.config/tunnel-client/playwright.yaml

/root/.config/mcp-tunnel-kit/serena.env
/root/.config/mcp-tunnel-kit/playwright.env
```

When upgrading from an older release, bootstrap automatically disables and removes the legacy GitHub tunnel service, profile, secret file, and installed GitHub MCP runtime.

Check all installed connectors:

```bash
mcp-stack-status
```

Rotate the shared OpenAI Control Plane key across all installed Linux connectors:

```bash
sudo rotate-mcp-control-plane-key
```

## Windows

Open PowerShell as Administrator:

```powershell
git clone https://github.com/nerdpremier/serena-lsp-kit.git
cd serena-lsp-kit
powershell -NoProfile -ExecutionPolicy Bypass -File .\bootstrap.ps1 -ProjectPath 'C:\path\to\project'
```

Non-interactive example:

```powershell
$env:SERENA_TUNNEL_ID = 'tunnel_...'
$env:PLAYWRIGHT_TUNNEL_ID = 'tunnel_...'
$env:CONTROL_PLANE_API_KEY = '...'
.\bootstrap.ps1 -ProjectPath 'C:\path\to\project'
```

Windows stores the runtime under:

```text
C:\ProgramData\McpTunnelKit
```

and creates two Scheduled Tasks:

```text
McpTunnelKit-Serena
McpTunnelKit-Playwright
```

The Windows installer removes the legacy `McpTunnelKit-GitHub` task and its runtime files during upgrade.

Check all installed connectors:

```powershell
& 'C:\ProgramData\McpTunnelKit\scripts\Mcp-Stack-Status.ps1'
```

For Playwright, Windows reuses Google Chrome Stable when available. If Chrome is missing, bootstrap installs `Google.Chrome` with `winget`; on x64 systems without `winget`, it falls back to Google's official Stable MSI after validating its Authenticode signature.

## Optional connectors

Serena is always installed. Playwright can be omitted intentionally.

Linux:

```bash
sudo ./bootstrap.sh /path/to/project --skip-playwright
```

Windows:

```powershell
.\bootstrap.ps1 -ProjectPath 'C:\project' -SkipPlaywright
```

## Versions pinned by this kit

```text
Serena               1.7.0
OpenAI tunnel-client 0.0.14
Node.js               24.21.0
Playwright MCP        0.0.80
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

## Playwright security defaults

Playwright MCP runs isolated and uses an explicit browser executable. On Linux, the tunnel remains root-owned while the Playwright MCP/browser child runs as an unprivileged user. Linux defaults to GUI/headed mode when an active desktop session is available.

For servers or CI:

```bash
sudo MCP_PLAYWRIGHT_HEADLESS=1 ./bootstrap.sh /absolute/path/to/project
```

On Windows, the kit uses Google Chrome Stable. Playwright output remains under the kit runtime directory.

## Secret handling

Profiles contain references such as:

```yaml
api_key: "env:CONTROL_PLANE_API_KEY"
```

They do not contain the actual OpenAI key.

Linux secret files are root-only (`0600`). Windows config/secret files get explicit ACLs for the installing user, SYSTEM, and Administrators.

Do not commit real tunnel IDs or OpenAI keys.

## Development

```bash
make test
```

CI validates Linux and Windows separately, including Python tests, ShellCheck, PowerShell parsing, and pinned upstream assets.

## License

MIT. Serena, tunnel-client, Node.js, Playwright MCP, Chromium, and MCP SDK retain their respective upstream licenses.
