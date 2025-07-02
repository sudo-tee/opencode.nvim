# AGENTS.md

## Build, Lint, and Test
- **Run all tests:** `./run_tests.sh`
- **Minimal tests:** `nvim --headless -u tests/minimal/init.lua -c "lua require('plenary.test_harness').test_directory('./tests/minimal', {minimal_init = './tests/minimal/init.lua', sequential = true})"`
- **Unit tests:** `nvim --headless -u tests/minimal/init.lua -c "lua require('plenary.test_harness').test_directory('./tests/unit', {minimal_init = './tests/minimal/init.lua'})"`
- **Run a single test:** Use the above command, replacing the directory with the test file path.
- **Lint:** No explicit lint command found; follow Lua best practices.

## Code Style Guidelines
- **Imports:** Use `local mod = require('mod')` at the top. Group standard, then project imports.
- **Formatting:** 2 spaces per indent. No trailing whitespace. Keep lines ≤ 100 chars.
- **Types:** Use Lua annotations (`---@class`, `---@field`, etc.) for public APIs and config.
- **Naming:**
  - Modules: `snake_case.lua`
  - Functions/vars: `snake_case` for local, `CamelCase` for classes/constructors
- **Error Handling:** Use `vim.notify` for user-facing errors. Return early on error.
- **Comments:** Only add if necessary for clarity. Prefer self-explanatory code.
- **Functions:** Prefer local functions. Use `M.func` for module exports.
- **Config:** Centralize in `config.lua`. Use deep merge for user overrides.
- **Tests:** Place in `tests/minimal/` or `tests/unit/`.
- **No Cursor or Copilot rules found.**

_This file is for agentic coding agents. Follow these conventions for consistency._
