# AGENTS.md

## Build, Lint, and Test

- **List development commands:** `make help`
- **Run all checks:** `make check`
- **Run all tests:** `make test`
- **Run a single test:** `make test TEST=tests/unit/test_example.lua`
- **Check types:** `make typecheck`
- **Check formatting:** `make format-check`
- **Launch replay tester:** `make replay`

## Formatting (Mandatory)

- After creating or editing Lua files, run StyLua on those files before marking the task complete: `stylua path/to/changed.lua ...`. Use the repository's `.stylua.toml` configuration.
- Format only files changed for the task. Do not reformat unrelated files unless explicitly requested.
- Run `make format-check` to verify workspace formatting. Report unrelated existing formatting failures rather than silently expanding the task.
- If StyLua is unavailable, report the blocker; do not claim formatting was validated.

# Developer Environment: EmmyLua Analyzer Rust (emmylua_ls)

- **Static Type Enforcement:** We use `emmylua-analyzer-rust` for strict type checking. Assume the LSP handles all type diagnostics.
- **Zero Defensive Over-Engineering:** Do not write manual runtime code (`type()`, `if nil`, or fallback operators) to catch typing errors. The Rust-backed LSP will catch them at compile-time.
- **Annotation-Only Contracts:** Document complex shapes using `---@class`, `---@alias`, and inline shapes. If a property or parameter is optional, strictly use the `?` marker (e.g., `---@param options? Table`).
- **Idiomatic Lua Flow:** Write clean, raw, performant Lua code. Let the application "fail fast" if code contract invariants are broken at runtime.
- **Comments:** Avoid obvious comments that merely restate what the code does. Only add comments when necessary to explain _why_ something is done, not _what_ is being done. Prefer self-explanatory code.

# Code Validation Step (Mandatory)

Before you mark a Lua code generation task as complete, you must validate your types against the project's static analysis rules:

1. Run `make typecheck` (which wraps `./check_types.sh`) over the generated workspace to execute `emmylua_check`.
2. Review the output for any static analysis diagnostics (e.g., syntax errors, type mismatches, missing fields).
3. If `emmylua_check` flags any type mismatches, you must fix the code's annotations or types—**do not write manual runtime boilerplate checking (`type()`) to quiet the linter**.
4. Iterate until `emmylua_check` passes with zero errors.

## Dependency Topology Tool

Use `scripts/dependency-topology/scan_topology.py` to inspect and track architectural layering.

- Use `python3 scripts/dependency-topology/scan_topology.py scan` to inspect current-state vs target-policy gap
- Use `diff` to inspect change direction (improved/regressed/neutral) between snapshots
- Pass `--snapshot <git-ref>` for historical snapshots
- Pass `--json` when feeding outputs into scripts or agents
- Keep architecture cleanup discussions anchored on scanner output instead of ad-hoc grep chains
