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

## Runtime Performance Profiling

Use this section when there is a runtime performance problem or a credible performance report: slow render, delayed keypress, streaming lag, startup slowdown, a profiler screenshot, or a benchmark/test showing a regression. Before changing code for that problem, capture evidence and reduce it to a cost model. Pick the profiling method by what is available; do not require a specific plugin.

### Capture options

Use the first option that fits the machine and the symptom.

#### Instrumentation profiler

Use this when a profiler plugin is already available. It records function call trees with time and count.

Example with `folke/snacks.nvim`, if it is installed:

```vim
:lua Snacks.profiler.start()
" reproduce the slow action once
:lua Snacks.profiler.stop({ pick = true })
```

Read it as a call tree. Parent time includes child time. `count` is useful for spotting repeated work.

#### LuaJIT sampling profiler

Use this when no profiler plugin is available. Neovim normally exposes LuaJIT's profiler as `jit.p`.

```vim
:lua require('jit.p').start('fl', '/tmp/nvim-jit-profile.log')
" reproduce the slow action once
:lua require('jit.p').stop()
```

Open `/tmp/nvim-jit-profile.log`. Treat it like a sampled CPU profile: it shows where Lua spent CPU time by stack/location, but it does not give exact call counts. If the issue is repeated work, pair it with a counter or scoped timer.

#### Scoped wall-time timer

Use this when the question is “which lifecycle boundary blocks the user?” or when sampling does not show wall-clock delay. Add temporary instrumentation around suspected boundaries only while investigating.

```lua
local uv = vim.uv or vim.loop
local start = uv.hrtime()
-- code under investigation
local elapsed_ms = (uv.hrtime() - start) / 1e6
vim.notify(string.format('opencode profile: <name> %.2fms', elapsed_ms))
```

For repeated calls, accumulate count and total time:

```lua
_G.opencode_perf = _G.opencode_perf or {}
local p = _G.opencode_perf[name] or { count = 0, total_ms = 0 }
p.count = p.count + 1
p.total_ms = p.total_ms + elapsed_ms
_G.opencode_perf[name] = p
```

Remove temporary instrumentation before committing unless the user explicitly asks for a diagnostic hook.

#### Startup profile

Use this only for startup or plugin-load regressions:

```bash
nvim --startuptime /tmp/nvim-startuptime.log
```

This is not a runtime action profiler. Do not use it to explain a slow keypress, render flush, or streaming callback.

### Interpret the profile

Start from the user-visible trigger, then walk down the stack.

Record:

```text
trigger:        <user action that starts the slow path>
blocking point: <render before display | keypress | streaming callback | startup>
hot stack:      <caller -> callee -> hotspot>
count:          <hotspot calls per trigger, or "sampled" if using jit.p>
cost:           <hotspot total time and per-call time if available>
repeated unit:  <message | part | line | file | buffer | session>
invariant data: <inputs that are unchanged across repeated calls>
```

Rules for reading evidence:

- In instrumentation traces, parent time includes child time. If parent and child times are almost equal, optimize the child or the child's call frequency.
- In sampling traces, sample share is not exact wall time and does not prove call count. Use it to find the hot stack, then verify count with instrumentation or counters.
- A 400 ms function called 10 times is a repeated-work problem. A 4 s function called once is a single expensive operation.
- Do not optimize tiny high-count helpers unless their caller stack explains the user-visible delay.

### Fix criteria

A valid fix must change one measured fact:

- remove expensive work from the blocking path;
- move invariant work to the smallest valid lifecycle boundary;
- defer work to an explicit user action;
- reduce repeated calls and prove the new call count with a test.

Do not add a cache until its invalidation boundary is named. Acceptable boundaries are concrete lifecycle points such as one render flush, one full session render, one keypress, one state change subscription, or one buffer change. Add a regression test that fails on the old call count.
