# AGENTS.md

## Build, Lint, and Test
- **Run all tests:** `./run_tests.sh`
- **Minimal tests:**
  `nvim --headless -u tests/minimal/init.lua -c "lua require('plenary.test_harness').test_directory('./tests/minimal', {minimal_init = './tests/minimal/init.lua', sequential = true})"`
- **Unit tests:**
  `nvim --headless -u tests/minimal/init.lua -c "lua require('plenary.test_harness').test_directory('./tests/unit', {minimal_init = './tests/minimal/init.lua'})"`
- **Run a single test:** Replace the directory in the above command with the test file path, e.g.:
  `nvim --headless -u tests/minimal/init.lua -c "lua require('plenary.test_harness').test_directory('./tests/unit/job_spec.lua', {minimal_init = './tests/minimal/init.lua'})"`
- **Lint:** No explicit lint command; follow Lua best practices.

## Code Style Guidelines
- **Imports:** `local mod = require('mod')` at the top. Group standard, then project imports.
- **Formatting:** 2 spaces per indent. No trailing whitespace. Lines ≤ 100 chars.
- **Types:** Use Lua annotations (`---@class`, `---@field`, etc.) for public APIs/config.
- **Naming:** Modules: `snake_case.lua`; functions/vars: `snake_case`; classes: `CamelCase`.
- **Error Handling:** Use `vim.notify` for user-facing errors. Return early on error.
- **Comments:** Only when necessary for clarity. Prefer self-explanatory code.
- **Functions:** Prefer local functions. Use `M.func` for module exports.
- **Config:** Centralize in `config.lua`. Use deep merge for user overrides.
- **Tests:** Place in `tests/minimal/` or `tests/unit/`.

_Agentic coding agents must follow these conventions strictly for consistency and reliability._
