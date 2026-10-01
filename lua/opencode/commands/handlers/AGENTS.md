# Command Handlers

Command adaptation + definitions only. Start with affected domain file; verify pipeline invariants against `commands/dispatch.lua`.

## Rules

- `M.actions`: command-facing adapters. `M.command_defs`: declarative desc/completions/execute. Keep both aligned by domain (window/session/diff/workflow/surface/agent/permission).
- No command parsing, direct `dispatch.execute`, hook routing, new bind/execute entry symbols (`*.run`, `bind_*`), or dispatch wrappers. Pipeline changes belong in command infrastructure.
- Keep action behavior identical across entries. Shared business logic belongs in services; follow root dependency/exception rules.
- Don't duplicate validation guaranteed by parse schema. Domain errors: `error({ code = 'invalid_arguments', ... }, 0)`.
- Bind `command_defs.<name>.execute = M.actions.<name>` directly when signatures match; avoid forwarding-only wrappers.
- Keep keymap compatibility aliases explicit, grouped, local; explain compatibility reason inline.
- Workflow changes must not spread unrelated UI orchestration.

## Regression Tests

- `./run_tests.sh -t tests/unit/commands_handlers_spec.lua`
- `./run_tests.sh -t tests/unit/commands_dispatch_spec.lua`
- `./run_tests.sh -t tests/unit/commands/command_axis_spec.lua`
- `./run_tests.sh -t tests/unit/api_spec.lua -f "command routing"`
