.DEFAULT_GOAL := help

TEST ?= all
FILTER ?=
FILE ?=
ARGS ?=
STYLUA ?= stylua
PYTHON ?= python3

LUA_GLOBS := -g '*.lua' -g '!deps/'
TOPOLOGY := scripts/dependency-topology/scan_topology.py
TOPOLOGY_REQUIREMENTS := scripts/dependency-topology/requirements.txt
# uv fetches the scanner's Python deps on demand; without uv, install them into $(PYTHON) first.
TOPOLOGY_PYTHON ?= $(if $(shell command -v uv),uv run --quiet --no-project --with-requirements $(TOPOLOGY_REQUIREMENTS) python3,$(PYTHON))
TOPOLOGY_BASE ?= origin/main

.PHONY: help check test test-minimal test-unit test-replay typecheck format-check format replay replay-regenerate topology topology-diff topology-check

help: ## List development commands
	@awk 'BEGIN { FS = ":.*## " } /^[a-z-]+:.*## / { printf "  %-20s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@printf '\nExamples:\n  make test TEST=tests/unit/formatter_spec.lua\n  make test TEST=unit FILTER="Timer"\n  make typecheck ARGS="-f github"\n  make replay ARGS="-c ReplayAll"\n  make replay-regenerate FILE=v2/formatters.json\n  make topology ARGS="--json"\n  make topology-diff ARGS="--from main --to HEAD --json"\n  make topology-check TOPOLOGY_BASE=upstream/main\n'

check: format-check typecheck test ## Run formatting, type checks, and all tests

test: ## Run tests (TEST=all|minimal|unit|replay|path; optional FILTER)
	./run_tests.sh -t "$(TEST)" $(if $(FILTER),-f "$(FILTER)") $(ARGS)

test-minimal: ## Run minimal tests
	$(MAKE) test TEST=minimal

test-unit: ## Run unit tests
	$(MAKE) test TEST=unit

test-replay: ## Run automated replay tests
	$(MAKE) test TEST=replay

typecheck: ## Check Lua types (optional ARGS passed to emmylua_check)
	./check_types.sh $(ARGS)

format-check: ## Check Lua formatting without modifying files
	$(STYLUA) --check . $(LUA_GLOBS) $(ARGS)

format: ## Format Lua files in place
	$(STYLUA) . $(LUA_GLOBS) $(ARGS)

replay: ## Launch interactive replay tester (optional Neovim ARGS)
	./tests/manual/run_replay.sh $(ARGS)

replay-regenerate: ## Regenerate snapshots with confirmation (optional FILE relative to tests/data)
	env -u VIM -u VIMRUNTIME ./tests/manual/regenerate_expected.sh $(if $(FILE),"$(FILE)")

topology: ## Scan dependency topology (optional scanner ARGS)
	$(TOPOLOGY_PYTHON) $(TOPOLOGY) scan $(ARGS)

topology-diff: ## Compare dependency topology snapshots (optional scanner ARGS)
	$(TOPOLOGY_PYTHON) $(TOPOLOGY) diff $(ARGS)

topology-check: ## Fail on new layer-rule breaks, import loops, or modules without a layer (vs TOPOLOGY_BASE)
	$(TOPOLOGY_PYTHON) $(TOPOLOGY) diff --from $(TOPOLOGY_BASE) --to worktree --check $(ARGS)
