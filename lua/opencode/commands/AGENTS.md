# Commands

Execution infrastructure, not feature surface. Read `parse.lua`, `init.lua`, `dispatch.lua` before editing.

## Pipeline and Rules

- All entries (`:Opencode`, keymap, API, slash): parse/build intent → `commands.bind_action_context(...)` → `dispatch.execute(ctx)` → hooks.
- `parse.lua`: structured intent only; never bind execute functions. `init.lua`: bind actions. `dispatch.lua`: lifecycle + error normalization.
- Single bind/execute points above. No `dispatch.run`, `route.execute`, fake parse wrappers, alternate bind paths, or per-entry semantic forks.
- Entry adapters use `commands.build_parsed_intent(...)` + `commands.execute_parsed_intent(...)`; no fallback branches checking whether these exist.
- Hooks: `before`, `after`, `error`, `finally`. Global: `command = '*'` or omitted; scoped: `command = 'run'` or `{'run','review'}`. Handlers must be side-effect aware and idempotent.
- Keep hook/action semantics consistent across entries. Preserve notify behavior unless explicitly requested.
- Prefer removing duplicate glue. Change handlers for feature behavior; change infrastructure only when all entries must change together.

## Regression Tests

- `./run_tests.sh -t tests/unit/commands_dispatch_spec.lua`
- `./run_tests.sh -t tests/unit/commands_parse_spec.lua`
- `./run_tests.sh -t tests/unit/commands/command_axis_spec.lua`
- `./run_tests.sh -t tests/unit/keymap_spec.lua`
- `./run_tests.sh -t tests/unit/api_spec.lua -f "command routing"`
