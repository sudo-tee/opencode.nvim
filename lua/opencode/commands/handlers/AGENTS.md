# AGENTS.md (handlers)

This directory owns command-facing action adapters and command definitions.

One-line positioning:
- `handlers/` = **command-entry adapters**
- `services/` = **cross-entry reusable business primitives**

## Scope

- `M.actions`: command-facing action adapters
- `M.command_defs`: command-facing definitions (desc/completions/execute)
- No command pipeline logic here

## Relation with services

- Handlers should call `services/*` when logic is shared by command/UI/quick_chat entries.
- Handlers should not become the only place for reusable business logic.
- If an action is needed outside command entry paths, move/keep it in `services/`.

## Hard Invariants

- Handlers do not call `dispatch.execute` directly
- Handlers do not parse command text
- Handlers do not decide hook routing
- Keep action behavior identical across entry points
- Handlers must not introduce any new bind/execute entry symbols (`*.run`, `bind_*`, or dispatch wrappers)
- Prefer `services/*` over direct new `opencode.session` / `opencode.api` requires in handlers

## Structure Guidance

- Keep `actions` and `command_defs` aligned by domain
- Keep keymap compatibility aliases explicit and grouped
- Avoid duplicating command validation already guaranteed by parse schema

## Current boundary debt (file-level TODO)

The following handler files still directly require `opencode.session` and should be routed via services APIs.

- [ ] `lua/opencode/commands/handlers/diff.lua` -> `opencode.session`
- [ ] `lua/opencode/commands/handlers/session.lua` -> `opencode.session`

Sync rule:
- keep this list aligned with `lua/opencode/services/AGENTS.md`
- remove an item only after code + tests pass

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
- Did we add any new direct `session/api` requires in handlers?

## Reject Conditions

- Any direct call to `dispatch.execute` from handlers
- Any parse/hook routing logic added to handlers
- Any new entry-style wrapper added in handlers
- Any new direct `require('opencode.session')` or `require('opencode.api')` in handlers without exception note

## Minimal Regression Commands

- `./run_tests.sh -t tests/unit/commands_handlers_spec.lua`
- `./run_tests.sh -t tests/unit/commands_dispatch_spec.lua`
- `./run_tests.sh -t tests/unit/commands/command_axis_spec.lua`
- `./run_tests.sh -t tests/unit/api_spec.lua -f "command routing"`

## Entry Notes For New Agents

- Start from the domain file you are touching (`window/session/diff/workflow/surface/agent/permission`), then verify invariants against `commands/dispatch.lua`.
- Treat handlers as **command adaptation + command definition only**.
- If you feel the need to touch parse/dispatch from handlers, stop and move that change to the command infrastructure layer.
- Keep compatibility aliases explicit, local, and justified inline.
