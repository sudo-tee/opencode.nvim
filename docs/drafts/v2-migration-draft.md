# Dual-protocol client: OpenCode V2 migration (DRAFT)

Status: draft, temporary. The authoritative spec lives outside git
(`docs/plans/v2-compat.md`, untracked by intent). This file exists so the
change is reviewable from the commit alone; delete or fold it into the
permanent docs once the migration is settled.

## The model

One writable fact store per session (the Observation). Protocol adapters are
the only writers; the UI is the only reader. Every V1/V2 difference is
absorbed inside a protocol adapter, so above the protocol boundary there is
exactly one code path and no protocol branching. Supporting V2 meant
replacing the V1-shaped middle layer (`api_client`, `event_manager`,
`session`, the per-scope event plumbing) with this boundary, not adding a
second track beside it.

A connection binds one protocol for its lifetime, chosen once by the
authenticated health probe. A protocol change is an identity change and
forces a reconnect.

## Where the wire contract comes from

The published OpenAPI spec and the running 2.0.x server disagree at several
endpoints. The adapters follow the running server; `tests/data/v2/`
fixtures are live captures, not guesses. Upstream dev already renames
permission/form events — bumping the server version means re-verifying the
event contract first.

## What the boundary absorbs

Differences between the protocols that would otherwise leak upward, with
where each is handled:

- History: V1 serves everything at once, V2 pages through a cursor. The
  observation holds the newest page and pulls older pages on demand
  (symmetric `load_older` / `load_complete_history`); the renderer declares
  how much history it needs. Long sessions thus fetch incrementally on
  navigation — the only user-visible behavior change.
- Usage: V2 reports server-side session totals; V1 does not. Both surface
  as the same session fact, with the V1 fallback derived from entries.
- Per-message settings exist only in V1; the single runtime protocol branch
  (in `services/messaging.lua`) is exactly there.
- Text encoding: mention ranges cross the UTF-16 boundary in both
  directions, and the encoding-argument forms of `vim.str_*` only exist on
  nvim 0.11+, so the adapters use version-independent converters in
  `util.lua`, verified against the native API case-by-case (CI floor is
  0.10.3).

## Verification

`./run_tests.sh` green on the CI matrix (0.10.3 → nightly), with per-protocol
contract specs, live captures as fixtures, and counterexample coverage
(cross-session pollution, malformed payloads, paging edge cases). Live
dual-client acceptance against a real 2.0.3 service is recorded in the spec.

## Known gaps (deliberate)

- Compaction/retry events are not rendered live; state converges on the
  next snapshot read.
- `form.replied` and `filesystem.changed` payload shapes lack event samples.
- `config.server.url` with an explicit port (no `server.port`) re-derives
  the port instead of using the URL as given.
