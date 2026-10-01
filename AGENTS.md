# AGENTS.md

## Commands

`make help` lists all. Key: `check` (format-check + typecheck + test), `test [TEST=path]`, `typecheck`, `format-check`, `replay`, `topology`, `topology-diff`. Extra flags: `ARGS="..."`.

## Before Finishing Lua Changes (Mandatory)

1. `stylua <changed files>` only; unrelated files only if asked.
2. `make format-check`; report unrelated failures, don't fix.
3. `make typecheck` until zero errors. Fix annotations, not runtime checks.
4. Tool missing → report blocker, don't claim validation.

## Lua Style

- Trust `emmylua_ls` strict diagnostics. Fail fast.
- No runtime type guards (`type()`, `if x == nil`, `or` fallbacks) on typed contracts.
- Contracts via `---@class`, `---@alias`, inline shapes; optional via `?`.
- Comments explain why, not what.

## Architecture

Entry (`ui/**`, `commands/handlers/**`, `quick_chat.lua`) → `services/*` → infra (`session`, `api`, `server_job`).

- Services: permanent boundary, own shared business logic. Handlers only adapt intents.
- New entry-layer `opencode.session`/`opencode.api` import: needs approval + PR note (reason, file + symbol, removal condition).
- No pass-through shims/facades. Keep changes local, reversible.
- New service contract: define name, inputs, outputs, failure behavior first. Never silently change existing ones.

## Topology

Use scanner, not grep, for architecture/debt. Remove debt only after code + tests pass.

- `make topology`: gap vs target policy.
- `make topology-diff ARGS="--from main --to HEAD"`: improved/regressed/neutral.
- Flags: `--json`, `--snapshot <git-ref>`. Docs: `scripts/dependency-topology/README.md`.
