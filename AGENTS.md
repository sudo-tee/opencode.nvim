# AGENTS.md

## Build, Lint, and Test

- **Run all tests:** `./run_tests.sh`
- **Run a single test:** Replace the directory in the above command with the test file path, e.g.:
  - `./run_tests.sh -t tests/unit/test_example.lua`

## Code Style Guidelines

- **Comments:** Avoid obvious comments that merely restate what the code does. Only add comments when necessary to explain _why_ something is done, not _what_ is being done. Prefer self-explanatory code.
- **Config:** Centralize in `config.lua`. Use deep merge for user overrides.
- **Types:** Use Lua annotations (`---@class`, `---@field`, etc.) for public APIs/config.

## Dependency Topology Tool

Use `scripts/dependency-topology/scan_topology.py` to inspect and track architectural layering.

- Use `python3 scripts/dependency-topology/scan_topology.py scan` to inspect current-state vs target-policy gap
- Use `diff` to inspect change direction (improved/regressed/neutral) between snapshots
- Pass `--snapshot <git-ref>` for historical snapshots
- Pass `--json` when feeding outputs into scripts or agents
- Keep architecture cleanup discussions anchored on scanner output instead of ad-hoc grep chains
