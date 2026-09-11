SHELL := /bin/bash

.PHONY: test syntax

test: syntax
	python3 -m unittest discover -s tests -v

syntax:
	python3 -m py_compile scripts/patch_serena.py scripts/configure_runtime.py
	bash -n install.sh rollback.sh scripts/update_tunnel_client.sh scripts/serena-stack-status scripts/rotate-serena-control-plane-key
	@if command -v shellcheck >/dev/null 2>&1; then shellcheck install.sh rollback.sh scripts/*.sh scripts/serena-stack-status scripts/rotate-serena-control-plane-key; else echo "shellcheck not installed; skipping"; fi
