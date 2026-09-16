# opencode.nvim architecture (DRAFT)

## The proposition

One writable fact store per session — the Observation. Protocol adapters are
the only writers; the presentation layer is the only reader. Everything below
follows from this: the layer shape, the contract at the read/write line,
where protocol differences die, and how far the current code is from it.

Dual-protocol support (V1 1.18.x, V2 2.0.x) is the forcing function, not the
subject: keeping two wire protocols honest is what exposed where the
boundaries are.

## The layer shape

```text
Entry          keymap / commands / pickers        user intent, nothing else
Dispatch       commands registry + parse           intent routing only
Domain         services.*                          facts & operations;
                                                  writes facts only through
                                                  protocol adapters
Presentation   ui.* (renderer, windows, tabs)     reads the Observation;
                                                  never writes session facts
Infrastructure server_job / Connection /          the only Observation
              transport / protocols/v1|v2         writers; protocol truth
Foundation     config / state / util / promise    passive; no layer rules
```

Infrastructure is the only layer shown in detail, because it is the only
boundary that has already hardened:

```text
Connection acquisition (server_job.lua)
  -> authenticated health probe decides the protocol, once per connection
  -> ready Connection (opencode_server.lua)
        +-- transport.lua            # raw HTTP/SSE bytes, cancellation
        +-- protocols/http.lua       # query, JSON, path-mapping mechanics
        +-- protocols/v1|v2/operations.lua   # native endpoints per protocol
        +-- protocols/v1|v2/observation.lua  # native events, recovery, admission
        `-- Observation per session  # single writable fact store per session
ui/renderer.lua -> watches Observation resources, re-reads on change
```

The Domain/Presentation line above is a declaration, not yet a fact — the
measured distance is in the last section. The old middle layer
(`api_client`, `event_manager`, `session`, `ui/renderer/events`,
`ui/event_scope`, `ui/session_scope`) was removed to make room for it.
Session tabs (logical tabs per session, from upstream) keep one renderer
context per tab and re-attach through the Observation path, not a parallel
event scope.

## The contract

The only interface between protocol adapters and everything above:

```text
read()                          snapshot of the session facts
watch(resources, callback)      per-subscription change notices
load_older()                    pull and merge one older history page
load_complete_history()         loop until the history is complete
submit(content)                 user input -> submission evidence
wait_until_idle()               session idle with provable outcome (V2 only)
interrupt()                     server response to the interrupt request
reply_permission(request, answer)
reply_question(request, answers)
reject_question(request)
```

Naming follows the domain, never the wire protocol: no method exposes event
names, payload shapes, or paging cursors. A concept enters this contract only
when an adapter cannot absorb it. `wait_until_idle` is the worked example:
V1 1.18.x's `session.idle` event carries only a `sessionID` — no outcome, no
error, no binding to a submission — so V1 honestly does not provide it.

## The absorption rules

Protocol differences die inside adapters. What each difference became:

- **Protocol identity** — one authenticated health probe per connection
  decides V1/V2 for the connection's lifetime; a protocol change is an
  identity change and forces a reconnect. Discovery and credentials come
  from the `opencode` CLI on V2; local spawn / explicit URL / port
  coordination on V1. Neovim exiting never kills the native shared service.
- **History** — V1 serves the whole history in one response; V2 pages
  through a cursor. The Observation holds the newest page and pulls older
  pages on demand (`load_older` / `load_complete_history`); long sessions
  fetch incrementally on navigation — the only user-visible behavior change.
- **Usage** — V2 emits server-side session totals; V1 does not. Both
  surface as the same session fact, with the V1 fallback derived from
  entries. Malformed payloads surface as `sync.session` errors and trigger a
  resource re-read; foreign-session events are rejected at the boundary.
- **Per-message settings** exist only in V1 — the single explicit runtime
  branch (in `services/messaging.lua`).

## Current distance

The same store/reader split names the boundary still missing in the middle:
Domain (services) and Presentation (ui) form one tangled layer today. The
`dependency-topology` scanner measures the distance:

- one 40-module strongly-connected component spanning entry to ui, glued
  mainly by services calling ui containers (`session_runtime`,
  `agent_model` → `ui.ui`, `input_window`)
- 8 policy violations (windows bind keymaps, pickers call `api` directly,
  `ui.ui` wires autocmds and contextual actions)
- 3 two-module cycles, each one edge away from acyclic

Convergence is incremental, not a rewrite: mechanical violation fixes first,
then the Domain/Presentation split as three local decisions (orchestration
ownership, services unidirectionality, `ui.ui` decomposition). Refer to this
section when picking follow-up work; `topology.jsonc` is the machine-checked
form of the goal, this document the narrative one.

## Evidence base

The published OpenAPI spec and the running 2.0.x server disagree at several
endpoints (`/api/project/current`, `rename` via POST, `command` field name,
`fork` body shape). The adapters follow the running server; `tests/data/v2/`
fixtures are live captures from a real server, not hand-written guesses. V1
1.18.30 is pinned to source + fixtures and exercised offline; the V1
`session.idle` payload shape was re-verified against a live 1.18.21 server.

Known future break point: upstream dev already renames `permission.asked` /
`form.*` events (`permission.v2.asked`, `question.v2.asked`). Bumping the
server version means re-verifying the event contract first.

Verification: `./run_tests.sh` green on the CI matrix (nvim 0.10.3 →
nightly; mention ranges cross the UTF-16 boundary in both directions, and
the encoding-argument forms of `vim.str_*` only exist on 0.11+, so the
adapters use the version-independent converters in `util.lua`, verified
case-by-case against the native API). Contract tests per protocol:
`protocol_{v1,v2}_{operations,observation}*_spec.lua`, with counterexample
coverage (cross-session pollution, malformed payloads, duplicate terminal
events, admission races, paging edge cases). Live dual-client acceptance
against a real 2.0.3 service is recorded in the project spec.

## Known gaps (deliberate)

- V1 `list_agents` / `list_commands` exports have no production callers (V1
  reads config directly); kept for symmetry with V2's live equivalents.
- Compaction progress events (`session.compaction.*`) and retry/revert
  events are not rendered live; state converges on the next snapshot read.
- `form.replied` payload shape and `filesystem.changed` data shape lack
  event samples; they are the current blind spots to close.
- `config.server.url` containing an explicit port without `server.port`
  re-derives the port from the SSH port-mapping table (or falls back to a
  local spawn) instead of using the URL as given.
