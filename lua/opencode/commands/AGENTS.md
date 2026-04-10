# AGENTS.md (commands)

This directory defines the command execution pipeline.

## Scope

- Parse command input into structured intent (`parse.lua`)
- Bind intent to executable action (`init.lua`)
- Execute lifecycle (`dispatch.lua`)
- Wire slash/keymap/API into the same axis

## Hard Invariants

- Single execution entry: `dispatch.execute(ctx)`
- Single bind point: `commands.bind_action_context(...)`
- `parse.lua` does not bind execute functions
- No `dispatch.run`, no `route.execute`, no fake parse wrapper

## Hook Model

- Stage hooks: `before`, `after`, `error`, `finally`
- Global hook: no command filter (`command = '*'` or omitted)
- Command-scoped hook: `command = 'run'` or `{'run','review'}`
- Keep hook handlers side-effect aware and idempotent

## Expected Execution Shape

```text
entry (:Opencode | keymap | API | slash)
  -> parse/build intent
  -> bind_action_context (single bind point)
  -> dispatch.execute (single execute point)
  -> hooks(before/after/error/finally)
```

## Editing Rules

- Prefer deleting duplicated glue code over adding adapters
- Keep error normalization in `dispatch.lua`
- Keep notify behavior unchanged unless explicitly requested
- Do not split semantics by entry (`:Opencode` / keymap / API / slash)

## Allow / Disallow Examples

- Allowed:
  - entry adapters call `commands.build_parsed_intent(...)` + `commands.execute_parsed_intent(...)`
  - infra changes that keep `dispatch.execute(ctx)` as the single execute entry
- Disallowed:
  - fallback branches such as `if commands.execute_parsed_intent then ... else ...`
  - building action context outside `commands.bind_action_context(...)`
  - adding per-entry behavior forks (`if source == 'keymap' then ...`)

## Quick Review Checklist

- Does new code bypass `dispatch.execute`?
- Does new code create a second bind path?
- Does parse start carrying execute logic again?
- Are hook semantics consistent for all entries?

## Reject Conditions

- Any new execute entry besides `dispatch.execute`
- Any new bind path besides `bind_action_context`
- Parse starts binding execute functions again

## Minimal Regression Commands

- `./run_tests.sh -t tests/unit/commands_dispatch_spec.lua`
- `./run_tests.sh -t tests/unit/commands_parse_spec.lua`
- `./run_tests.sh -t tests/unit/commands/command_axis_spec.lua`
- `./run_tests.sh -t tests/unit/keymap_spec.lua`
- `./run_tests.sh -t tests/unit/api_spec.lua -f "command routing"`

## Entry Notes For New Agents

- Read `parse.lua`, `init.lua`, `dispatch.lua` in this order before editing.
- Treat this directory as **execution infrastructure**, not feature surface.
- If a change needs new behavior, prefer changing handlers first; only touch command infrastructure when all entries must change together.
- Keep edits local and reversible: no new execution entry, no new bind path, no per-entry semantic split.
