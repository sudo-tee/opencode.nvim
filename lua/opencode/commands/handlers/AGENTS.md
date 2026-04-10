# AGENTS.md (handlers)

This directory owns domain actions and command definitions.

## Scope

- `M.actions`: domain operations
- `M.command_defs`: command-facing definitions (desc/completions/execute)
- No command pipeline logic here

## Hard Invariants

- Handlers do not call `dispatch.execute` directly
- Handlers do not parse command text
- Handlers do not decide hook routing
- Keep action behavior identical across entry points
- Handlers must not introduce any new bind/execute entry symbols (`*.run`, `bind_*`, or dispatch wrappers)

## Structure Guidance

- Keep `actions` and `command_defs` aligned by domain
- Keep keymap compatibility aliases explicit and grouped
- Avoid duplicating command validation already guaranteed by parse schema

## Editing Rules

- Prefer consolidation over introducing new layers
- Keep domain boundaries clear (window/session/diff/workflow/surface/agent/permission)
- If adding command aliases, document compatibility reason inline
- If touching workflow, avoid spreading unrelated UI orchestration further

## Allow / Disallow Examples

- Allowed:
  - `command_defs.<name>.execute = M.actions.<name>` direct binding when signature already matches
  - explicit alias blocks for keymap compatibility
  - domain validation errors using `error({ code = 'invalid_arguments', ... }, 0)`
- Disallowed:
  - parsing command text in handlers (`vim.split(args_line, ...)` style parsing)
  - dispatch routing in handlers (`dispatch.execute`, hook stage decisions)
  - hidden wrapper layers that only forward params without adding behavior

## Quick Review Checklist

- Is business behavior in `actions`, not in dispatch glue?
- Is `command_defs` declarative and minimal?
- Are aliases grouped and obvious?
- Did we avoid reintroducing duplicate argument validation paths?

## Reject Conditions

- Any direct call to `dispatch.execute` from handlers
- Any parse/hook routing logic added to handlers
- Any new entry-style wrapper added in handlers

## Minimal Regression Commands

- `./run_tests.sh -t tests/unit/commands_handlers_spec.lua`
- `./run_tests.sh -t tests/unit/commands_dispatch_spec.lua`
- `./run_tests.sh -t tests/unit/commands/command_axis_spec.lua`
- `./run_tests.sh -t tests/unit/api_spec.lua -f "command routing"`

## Entry Notes For New Agents

- Start from the domain file you are touching (`window/session/diff/workflow/surface/agent/permission`), then verify invariants against `commands/dispatch.lua`.
- Treat handlers as **domain behavior + command definition only**.
- If you feel the need to touch parse/dispatch from handlers, stop and move that change to the command infrastructure layer.
- Keep compatibility aliases explicit, local, and justified inline.
