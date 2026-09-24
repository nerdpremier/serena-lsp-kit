SHELL := /bin/bash

PY_SCRIPTS := scripts/patch_serena.py scripts/configure_runtime.py scripts/multi_mcp_config.py
SH_SCRIPTS := bootstrap.sh install.sh rollback.sh \
	scripts/update_tunnel_client.sh scripts/update_uv.sh scripts/update_node.sh scripts/update_node_playwright.sh \
	scripts/serena-stack-status scripts/mcp-stack-status scripts/rotate-serena-control-plane-key

.PHONY: test syntax

test: syntax
	python3 -m unittest discover -s tests -v

syntax:
	python3 -m py_compile $(PY_SCRIPTS)
	bash -n $(SH_SCRIPTS)
	@if command -v shellcheck >/dev/null 2>&1; then shellcheck $(SH_SCRIPTS); else echo "shellcheck not installed; skipping"; fi
	@if command -v pwsh >/dev/null 2>&1; then pwsh -NoProfile -Command '$$files=@("bootstrap.ps1","scripts/Run-McpTunnel.ps1","scripts/Mcp-Stack-Status.ps1"); foreach($$f in $$files){$$e=$$null;$$t=$$null;[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $$f),[ref]$$t,[ref]$$e)|Out-Null;if($$e.Count){$$e|ForEach-Object{Write-Error (("{0}: {1}" -f $$f,$$_.Message))};exit 1}}'; else echo "pwsh not installed; skipping PowerShell syntax"; fi
