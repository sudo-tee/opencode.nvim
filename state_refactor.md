```markdown
# State Refactor Plan

## Goal

Refactor the plugin global state into a small store + slice modules so writes are funneled through safe, domain-owned APIs while preserving existing read semantics and notification timing.

## Recommended starting work (default)

Implement the store primitive, add a test escape hatch to silence protected-write warnings, and extract the `session` and `jobs` slices. This gives immediate safety for the highest-value mutation domains and a clear migration path for the rest.

## High-level roadmap

1. store: implement `lua/opencode/state/store.lua` (get/set/update/subscribe/notify) preserving current scheduling semantics.
2. test escape hatch: add a way for tests to set raw state without warnings (e.g. `store.set_raw` or an env var), plus `lua/opencode/state/test_helpers.lua`.
3. slices: create `lua/opencode/state/session.lua` and `lua/opencode/state/jobs.lua` that use store APIs and expose the existing helper signatures.
4. facade: create `lua/opencode/state/init.lua` to re-export store and slices and to preserve backward-compatible read access for callers still requiring `require('opencode.state')`.
5. migrate callers in small batches (server/jobs first, then UI and model).
6. add small lifecycle helpers/state machines in `state/jobs.lua` and `state/ui.lua`.
7. tighten policy (warnings -> errors) and cleanup once tests and migration are complete.

## Concrete tasks

- store
  - File: `lua/opencode/state/store.lua`
  - API:
    - `get(key)`
    - `set(key, value, opts?)` where `opts.source` is `'helper'|'raw'` and controls warnings
    - `update(key, fn, opts?)`
    - `subscribe(key_or_pattern, cb)` (support key-based subscriptions; preserve scheduling semantics)
    - `notify(...)` (optional internal)
  - Behavior:
    - Preserve current notification timing (use `vim.schedule` if current code does)
    - Centralize `PROTECTED_KEYS` logic and warn once per key on raw writes
    - Provide `set_raw` or `set(key, value, {silent=true})` for tests

- test escape hatch
  - File: `lua/opencode/state/test_helpers.lua` (or export functions from `store`)
  - API:
    - `silence_protected_writes()` / `allow_raw_writes_for_tests()` — minimal API for test suites
  - Usage:
    - Tests can call the helper in a setup block to avoid noisy warnings while they directly mutate state

- session slice
  - File: `lua/opencode/state/session.lua`
  - Exported helpers (match existing names):
    - `set_active(session, opts?)`
    - `clear_active()`
    - `set_restore_points(points)`
    - `reset_restore_points()`
    - any other session helpers already in  `lua/opencode/state.lua`
  - Implementation:
    - Use `store.set`/`update` and `store.subscribe` where necessary
    - Keep call-site signatures unchanged

- jobs slice
  - File: `lua/opencode/state/jobs.lua`
  - Exported helpers:
    - `increment_count()`
    - `decrement_count()` (if required)
    - `set_count(n)`
    - `set_server(server)`
    - `clear_server()`
    - small lifecycle helpers like `ensure_server()`/`on_server_start()` optionally
  - Implementation:
    - Use `store` primitives; centralize server lifecycle transitions

- facade/init
  - File: `lua/opencode/state/init.lua` (module returned by `require('opencode.state')`)
  - Re-export:
    - `store` or thin read-proxy for backward compatibility
    - `session`, `jobs`, `ui`, `model` slices as they become available
  - Behavior:
    - Reads (e.g., `state.some_key`) should continue to work for existing code
    - Writes should be routed through slices or still emit protected-write warnings if raw

## Migration strategy

- Do not change everything in one PR. Use multiple, small PRs:
  1. Add `store.lua`, `test_helpers.lua`, no callers changed.
  2. Add `state/session.lua` and `state/jobs.lua`.
  3. Add `state/init.lua` facade; update a small set of callers to require new slices or to call `state.session.*`.
  4. Migrate other call sites in batches (server/job, then UI, then model).
  5. Final cleanup and tighten warning policy.
- After each change: run  `./run_tests.sh` and fix failures.
- For tests that directly mutate `state.*`, either:
  1. Use the test helper to silence warnings, or
  2. Update tests to use the new slice helpers (preferred long term).

## Files to create (initial)

- `lua/opencode/state/store.lua`
- `lua/opencode/state/test_helpers.lua`
- `lua/opencode/state/session.lua`
- `lua/opencode/state/jobs.lua`
- `lua/opencode/state/init.lua`

## Testing & verification

- Run unit tests after each step:  `./run_tests.sh`
- Manually exercise UI/server flows for timing-sensitive behavior (notifications should be scheduled same as before)
- Verify that protected-key warnings are logged once per key and that tests can silence them via test helper
- Grep for raw writes: `rg "state\.[a-zA-Z_][a-zA-Z0-9_]*\s*="` and migrate the important ones first (session, jobs, ui, model)

## Commit & PR guidance

- Keep commits small and descriptive:
  1. "feat(state): add store primitive and test helpers"
  2. "feat(state/session, jobs): move session and jobs helpers to slices"
  3. "refactor(state): add facade and wire slice exports"
  4. "refactor: migrate server/job call sites to state.jobs API"
- Each PR should aim to be test-green and include a short migration note.
- Don’t amend commits; create new commits for fixes.

## Timing & milestones (example)

- Day 1: Implement `store.lua` + `test_helpers.lua` + unit tests for store behavior
- Day 2: Implement `session.lua` + `jobs.lua`, add tests for slices
- Day 3: Add `state/init.lua` facade and migrate a small set of callers
- Day 4: Migrate remaining high-value callers, run full test suite
- Day 5: Small cleanups, tighten warnings (optional)

## Risks & mitigations

- Risk: notification/timing changes introduce subtle bugs
  - Mitigation: preserve `vim.schedule` usage and run integration-like tests
- Risk: tests fail due to direct state mutation
  - Mitigation: provide test escape hatch and gradually update tests to use new helpers
- Risk: large PRs are hard to review
  - Mitigation: split work into small PRs focused on one slice or behavior at a time

## Open questions (pick one)

1. Start now with the recommended default: implement `store + test escape hatch + session + jobs`? (Recommended)
2. Or would you prefer I extract a different slice first (e.g. `ui` or `model`)?

If you pick (1), I will produce ready-to-apply code snippets for:

- `lua/opencode/state/store.lua`
- `lua/opencode/state/test_helpers.lua`
- `lua/opencode/state/session.lua`
- `lua/opencode/state/jobs.lua`
- `lua/opencode/state/init.lua`

You can then paste them into files or ask me to apply them to the repository.
```

## Next step

- Reply with the option you want (1 = default store+tests+session+jobs, 2 = extract different slice first) or edit the markdown above and tell me which parts to change.
