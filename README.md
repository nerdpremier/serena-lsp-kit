# Serena LSP Kit

A small, reproducible hardening kit for running **Serena 1.7.0** through the OpenAI MCP tunnel in **LSP-only** mode.

This repository packages the fixes we use locally to make Serena more predictable for long coding sessions:

- pins the tunnel client to `0.0.14`
- starts Serena with an explicit project path so the active project survives reconnects
- moves tunnel health off port `8080` (default: `18090`)
- lowers Serena tool timeout/output limits to avoid oversized or stale MCP responses
- reduces Serena logging to warning/error level
- adds per-project ignores for virtualenvs, node_modules, build output and tool caches
- moves the Control Plane API key out of the systemd unit into a root-only `EnvironmentFile`
- removes JetBrains-specific tools from the Serena runtime registry and makes the installation intentionally LSP-only
- installs safe status and API-key rotation helpers
- keeps backups so the Serena package patch can be rolled back

## Scope

This kit is intentionally narrow. It currently supports:

- Linux with systemd
- Serena `1.7.0`, installed as the `serena-agent` uv tool
- OpenAI `tunnel-client` `0.0.14`
- one explicit Serena project per tunnel profile

It does **not** vendor Serena, tunnel-client, credentials, or any project source code.

## Install

Run as root and pass the project that Serena should activate automatically:

```bash
sudo ./install.sh /absolute/path/to/project --restart
```

Without `--restart`, all changes are staged and validated but the running tunnel is left untouched:

```bash
sudo ./install.sh /absolute/path/to/project
sudo systemctl restart serena-tunnel.service
```

Useful environment overrides:

```text
SERENA_CONFIG=/root/.serena/serena_config.yml
TUNNEL_DIR=/root/mcp-workspace/tunnel-client
TUNNEL_PROFILE=/root/.config/tunnel-client/chatgpt-mcp.yaml
TUNNEL_ENV=/root/.config/tunnel-client/serena-tunnel.env
SYSTEMD_UNIT=/etc/systemd/system/serena-tunnel.service
SERENA_SERVICE=serena-tunnel.service
SERENA_HEALTH_PORT=18090
```

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

## Rotate the Control Plane key

The installed helper never echoes the key and automatically restores the previous environment file if the tunnel fails its health check:

```bash
rotate-serena-control-plane-key
```

After rotating locally, revoke the old key in the OpenAI dashboard.

## LSP-only behavior

The installer removes `serena/tools/jetbrains_tools.py` from the installed Serena tool package after saving a backup. It also removes the unconditional JetBrains-tool import and patches Serena's backend configuration so:

- `LanguageBackend.LSP` behaves normally;
- no `jet_brains_*` tools are registered;
- attempting to switch that patched installation to the JetBrains backend fails with a clear message.

Some MCP clients cache tool schemas for the lifetime of a chat/session. After installing, a **new client session** may be required before stale `jet_brains_*` schemas disappear from the client UI.

## Rollback

The installer stores package/config backups under:

```text
/root/.serena/lsp-only-kit-backups/
```

Restore the most recent Serena package/config backup with:

```bash
sudo ./rollback.sh --restart
```

For security, rollback does **not** put an API key back into a systemd unit. The separate root-only environment file is intentionally preserved.

## Development

```bash
make test
```

The test suite uses temporary fixtures; it does not patch the machine running the tests.

## Security notes

- No API keys belong in this repository.
- `.env`, key, credential, backup, and runtime-secret files are ignored by Git.
- The systemd migration never prints the secret value.
- The key rotation helper reads the new key with terminal echo disabled.
- Third-party binaries are downloaded from their upstream release and verified against the upstream checksum file.

## License

MIT. This repository contains only the installer/patching glue authored for this kit; Serena and tunnel-client remain governed by their respective upstream licenses.
