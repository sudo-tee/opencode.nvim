# Services

Stable, minimal cross-entry business APIs; follow root architecture boundaries. Not a generic dumping ground.

## Responsibilities

- `session_runtime.lua`: shared session/runtime orchestration; switch/open/cancel; detached session creation + observation on same connection. No command parsing, UI rendering, or `session.lua` persistence internals.
- `messaging.lua`: send orchestration, after-run lifecycle, messaging-facing permission routing. No UI rendering, command routing, or model/mode selection policy.
- `agent_model.lua`: model/mode/provider/variant operations + selection orchestration. No session lifecycle, permission flows, or message pipeline.
- `messaging.lua` and `agent_model.lua`: no `vim.api`, `vim.fn`, or `vim.notify`.

## Regression Checks

- `./run_tests.sh`
- `! grep -n "vim\.api\|vim\.fn\|vim\.notify" lua/opencode/services/messaging.lua`
- `! grep -n "vim\.api\|vim\.fn\|vim\.notify" lua/opencode/services/agent_model.lua`
- Use root topology scanner commands to inspect dependency direction/debt.
