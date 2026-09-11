# Serena LSP Kit

A reproducible installer and hardening kit for running **Serena 1.7.0** through the **OpenAI MCP tunnel** in **LSP-only** mode.

## What this is

This repository is the setup layer for this connection path:

```text
ChatGPT / OpenAI MCP control plane
            |
            | outbound tunnel
            v
      tunnel-client 0.0.14
            |
            | stdio MCP
            v
        Serena 1.7.0
            |
            v
       your project
```

`serena-lsp-kit` is not a replacement for Serena or tunnel-client. It installs/configures them so a machine can expose one local Serena project to ChatGPT through the OpenAI tunnel reliably.

The kit:

- pins `tunnel-client` to `0.0.14` and verifies the upstream checksum
- installs Serena `1.7.0` on a fresh machine when needed
- starts Serena with an explicit project path so the active project survives reconnects
- uses LSP-only mode and removes JetBrains-specific Serena tools
- moves tunnel health off port `8080` (default: `18090`)
- reduces oversized/stale MCP responses with tighter Serena timeout/output limits
- adds project ignores for virtualenvs, node_modules, build output and caches
- stores the Control Plane API key in a root-only environment file, never in Git
- installs status, rollback, and API-key rotation helpers
- runs as a systemd service and can start automatically at boot

## What you need from OpenAI

A fresh machine needs only two OpenAI values:

1. **Tunnel ID** — looks like `tunnel_...`
2. **Control Plane API key** — supplied as `CONTROL_PLANE_API_KEY`

The tunnel profile stores only:

```yaml
control_plane:
  tunnel_id: "tunnel_..."
  api_key: "env:CONTROL_PLANE_API_KEY"
```

The actual API key is stored separately in:

```text
/root/.config/tunnel-client/serena-tunnel.env
```

with mode `0600`.

`tunnel-client --help` lists the canonical setup pages:

- Tunnels: `https://platform.openai.com/settings/organization/tunnels`
- API keys: `https://platform.openai.com/settings/organization/api-keys`
- ChatGPT connector settings: `https://chatgpt.com/#settings/Connectors`

Do not commit either a real API key or a machine-specific tunnel profile to this repository.

## Fresh machine install

Supported target: Linux with systemd, Python 3.11–3.14, `python3-venv`, `curl`, `unzip`, and `sha256sum`.

Clone the repository, then run:

```bash
git clone https://github.com/nerdpremier/serena-lsp-kit.git
cd serena-lsp-kit
sudo ./bootstrap.sh /absolute/path/to/project
```

The installer asks:

```text
OpenAI tunnel ID (tunnel_...):
OpenAI Control Plane API key:
```

The API-key input is hidden. After that, `bootstrap.sh` will:

1. install/use Serena `1.7.0`;
2. create Serena global/project config if missing;
3. install `tunnel-client 0.0.14`;
4. create the tunnel profile;
5. create the root-only key file;
6. validate the tunnel profile with `tunnel-client doctor`;
7. create/use `serena-tunnel.service`;
8. apply the LSP-only stability patch;
9. enable/start the service;
10. verify `/healthz` and `/readyz`.

You can provide the tunnel ID on the command line while still entering the key securely:

```bash
sudo ./bootstrap.sh /absolute/path/to/project --tunnel-id tunnel_...
```

For automated provisioning, `SERENA_TUNNEL_ID` and `CONTROL_PLANE_API_KEY` environment variables are also supported. Interactive key entry is preferred on shared systems.

## Existing installation

If Serena/tunnel-client are already configured and you only want the hardening changes:

```bash
sudo ./install.sh /absolute/path/to/project --restart
```

Without `--restart`, changes are staged and validated but the service is left running until you restart it yourself.

## Status

```bash
serena-stack-status
```

Healthy output should look like:

```text
service=active
tunnel_version=0.0.14+...
health=live
ready=ready
port_8080=FREE
serena_processes=1
tunnel_processes=1
recent_errors=0
```

## Rotate the Control Plane API key

```bash
rotate-serena-control-plane-key
```

The helper reads the new key with terminal echo disabled, restarts the service, checks health, and rolls the local key file back automatically if startup fails. Revoke the previous key in the OpenAI dashboard after a successful rotation.

## LSP-only behavior

The installer backs up Serena package files, removes `serena/tools/jetbrains_tools.py`, removes the unconditional JetBrains tool import, and makes this Serena installation intentionally LSP-only.

After installation:

- `LanguageBackend.LSP` works normally;
- `jet_brains_*` tools are not registered;
- selecting the JetBrains backend fails with a clear LSP-only message.

Some MCP clients cache tool schemas for the lifetime of a chat/session. Start a new client session after installation if old `jet_brains_*` schemas are still visible.

## Rollback

Backups are stored under:

```text
/root/.serena/lsp-only-kit-backups/
```

Restore the latest Serena package/config backup with:

```bash
sudo ./rollback.sh --restart
```

Rollback intentionally does not put an API key back into a systemd unit. The root-only environment file remains the credential source.

## Development

```bash
make test
```

Tests use temporary fixtures and do not modify the machine running the test suite. GitHub Actions runs Python syntax checks, shell syntax, ShellCheck, and unit tests on every push/PR.

## Security

- No API keys belong in this repository.
- `.env`, key, credential, backup, and runtime-secret files are ignored by Git.
- Fresh setup writes the key only to a `0600` root-owned environment file.
- The YAML profile references the key through `env:CONTROL_PLANE_API_KEY`.
- Secret values are never printed by the installer.
- The rotation helper uses hidden terminal input.
- `tunnel-client` release downloads are verified against the upstream `SHA256SUMS.txt`.

## License

MIT. This repository contains only the installer/patching glue authored for this kit; Serena and tunnel-client remain governed by their respective upstream licenses.
