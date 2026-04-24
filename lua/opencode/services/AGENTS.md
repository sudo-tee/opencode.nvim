# AGENTS.md (services)

One-line positioning:
- `services/` = **cross-entry reusable business primitives**
- `handlers/` = **command-entry adapters**

This directory defines the stable boundary between entry modules and infra-facing modules.

## Why this layer exists

`services/` exists to keep dependency growth controlled:

- entry modules (`ui/**`, `commands/handlers/**`, `quick_chat.lua`) call a small, stable service surface
- infra-facing modules (`session`, `api`, `server_job`, etc.) are not scattered across many entry files
- cross-entry orchestration logic stays here so behavior changes are localized and auditable

This is a structural boundary, not a temporary migration layer.

## Relation with handlers

- `handlers/` should adapt command intents to actions.
- `services/` should hold reusable business actions shared by command/UI/quick_chat entries.
- If logic is needed by non-command entry paths, it belongs in `services/`, not only in `handlers/`.

## Scope (responsible / not responsible)

- `session_runtime.lua`
  - Responsible for:
    - session/runtime orchestration shared by multiple entry modules
    - session switching/opening/cancel-related orchestration
  - Not responsible for:
    - command text parsing
    - UI rendering details (layout, buffer paint logic)
    - persistence/storage internals in `session.lua`

- `messaging.lua`
  - Responsible for:
    - message send flow orchestration
    - after-run lifecycle actions
    - permission action routing exposed as messaging-facing service API
  - Not responsible for:
    - direct UI rendering logic
    - command routing decisions
    - model/mode selection policy

- `agent_model.lua`
  - Responsible for:
    - model/mode/provider/variant operations
    - model selection-related orchestration API
  - Not responsible for:
    - session lifecycle orchestration
    - permission flow handling
    - message send pipeline

## Required dependency direction

```text
entry modules (ui/handlers/quick_chat)
  -> services/*
    -> infra-facing modules (session/api/server_job/...)
```

Disallowed shape:

```text
entry modules -> session/api (new direct scatter)
```

## Current boundary debt (file-level TODO)

The following entry files still directly require `opencode.session`/`opencode.api` and should be removed by routing through services APIs.

- [ ] `lua/opencode/quick_chat.lua` -> `opencode.session`
- [ ] `lua/opencode/ui/renderer.lua` -> `opencode.session`, `opencode.api`
- [ ] `lua/opencode/ui/debug_helper.lua` -> `opencode.session`
- [ ] `lua/opencode/ui/permission_window.lua` -> `opencode.api`
- [ ] `lua/opencode/ui/contextual_actions.lua` -> `opencode.api`
- [ ] `lua/opencode/ui/session_picker.lua` -> `opencode.api`
- [ ] `lua/opencode/ui/timeline_picker.lua` -> `opencode.api`
- [ ] `lua/opencode/ui/ui.lua` -> `opencode.api`
- [ ] `lua/opencode/commands/handlers/diff.lua` -> `opencode.session`
- [ ] `lua/opencode/commands/handlers/session.lua` -> `opencode.session`

Sync rule:
- keep this list aligned with `lua/opencode/commands/handlers/AGENTS.md`
- remove an item only after code + tests pass

## Hard invariants

- Entry modules must prefer `services/*` over adding new direct `opencode.session` / `opencode.api` requires
- `messaging.lua` and `agent_model.lua` must stay logic-oriented:
  - no `vim.api`
  - no `vim.fn`
  - no `vim.notify`
- Do not add adapter/shim/facade compatibility shells inside `services/`
- Do not silently change behavior contracts of existing service APIs

## Reject conditions

Reject a change if any of these happens:

- New direct entry-layer `require('opencode.session')` or `require('opencode.api')` is introduced without explicit exception approval
- A new compatibility wrapper layer is added only to mask boundary drift
- Unrelated responsibilities are moved into `services/` without boundary update and contract definition

## Exception policy

If a direct entry-layer dependency on `session/api` is temporarily unavoidable, the change must include:

- explicit exception note in the PR description
- reason and scope (file + symbol)
- planned removal condition

No implicit exceptions.

## Editing rules

- Prefer removing scattered direct dependencies over adding glue layers
- Keep service APIs explicit and minimal
- Before introducing a new shared service API, define and freeze its contract (name, inputs, outputs, failure behavior)
- Keep changes local and reversible

## Minimal regression commands

- `./run_tests.sh`
- `rg -n "require\(['\"]opencode\.(session|api)['\"]\)" lua/opencode/ui lua/opencode/commands/handlers lua/opencode/quick_chat.lua`
- `! grep -n "vim\.api\|vim\.fn\|vim\.notify" lua/opencode/services/messaging.lua`
- `! grep -n "vim\.api\|vim\.fn\|vim\.notify" lua/opencode/services/agent_model.lua`

## Notes for new agents

Treat `services/` as a boundary-control layer:

- keep entry-to-infra coupling from spreading
- keep service contracts stable
- avoid turning this directory into a generic dumping area
