# AGENTS.md

## Build, Lint, and Test

- **Run all tests:** `./run_tests.sh`
- **Minimal tests:** `./run_tests.sh -t minimal`
  `nvim --headless -u tests/minimal/init.lua -c "lua require('plenary.test_harness').test_directory('./tests/minimal', {minimal_init = './tests/minimal/init.lua', sequential = true})"`
- **Unit tests:** `./run_tests.sh -t unit`
  `nvim --headless -u tests/minimal/init.lua -c "lua require('plenary.test_harness').test_directory('./tests/unit', {minimal_init = './tests/minimal/init.lua'})"`
- **Replay tests:** `./run_tests.sh -t replay`
  `nvim --headless -u tests/minimal/init.lua -c "lua require('plenary.test_harness').test_directory('./tests/replay', {minimal_init = './tests/minimal/init.lua'})"`
- **Run a single test:** Replace the directory in the above command with the test file path, e.g.:
  `nvim --headless -u tests/manual/init.lua -c "lua require('plenary.test_harness').test_directory('./tests/unit/job_spec.lua', {minimal_init = './tests/minimal/init.lua'})"`
- **Manual/Visual tests:** `./tests/manual/run_replay.sh` - Replay captured event data for visual testing
- **Debug rendering in headless mode:**
  `nvim --headless -u tests/manual/init_replay.lua "+ReplayHeadless" "+ReplayLoad tests/data/FILE.json" "+ReplayAll 0" "+qa"`
  This will replay events and dump the output buffer to stdout, useful for debugging rendering issues without a UI.
  You can also run to just a specific message # with (e.g. message # 12):
  `nvim --headless -u tests/manual/init_replay.lua "+ReplayHeadless" "+ReplayLoad tests/data/message-removal.json" "+ReplayNext 12" "+qa"`
- **Lint:** No explicit lint command; follow Lua best practices.

## Code Style Guidelines

- **Imports:** `local mod = require('mod')` at the top. Group standard, then project imports.
- **Formatting:** 2 spaces per indent. No trailing whitespace. Lines ≤ 100 chars.
- **Types:** Use Lua annotations (`---@class`, `---@field`, etc.) for public APIs/config.
- **Naming:** Modules: `snake_case.lua`; functions/vars: `snake_case`; classes: `CamelCase`.
- **Error Handling:** Use `vim.notify` for user-facing errors. Return early on error.
- **Comments:** Avoid obvious comments that merely restate what the code does. Only add comments when necessary to explain *why* something is done, not *what* is being done. Prefer self-explanatory code.
- **Functions:** Prefer local functions. Use `M.func` for module exports.
- **Config:** Centralize in `config.lua`. Use deep merge for user overrides.
- **Tests:** Place in `tests/minimal/`, `tests/unit/`, or `tests/replay/`. Manual/visual tests in `tests/manual/`.

_Agentic coding agents must follow these conventions strictly for consistency and reliability._

## File Reference Detection

The plugin automatically detects file references in LLM responses and makes them navigable via the reference picker (`<leader>or` or `:Opencode references`).

### Supported Formats

The reference picker recognizes these file reference patterns:

1. **Backtick-wrapped** (recommended by LLMs naturally):
   - `` `path/to/file.lua` ``
   - `` `path/to/file.lua:42` ``
   - `` `path/to/file.lua:42:10` `` (with column)
   - `` `path/to/file.lua:42-50` `` (line range)

2. **file:// URIs** (backward compatibility):
   - `file://path/to/file.lua`
   - `file://path/to/file.lua:42`
   - `file://path/to/file.lua:42-50`

3. **Plain paths** (natural format):
   - `path/to/file.lua`
   - `path/to/file.lua:42`
   - `./relative/path.lua:42`
   - `/absolute/path.lua:42`

All formats support both relative and absolute paths. Files must exist to be recognized (validation prevents false positives).

**No system prompt configuration is required** - the parser works with all LLM providers, including those without system prompt support.
