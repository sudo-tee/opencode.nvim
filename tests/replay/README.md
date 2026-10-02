# JSON snapshot replays

`make test-replay` discovers `tests/data/**/*.expected.json` and replays the
matching input JSON. Behavior tests live in `tests/unit`.

Shared snapshot comparison decodes valid fenced JSON before comparing values,
ignoring object-key order and equivalent escaping. Array order, surrounding text,
line positions, extmarks, and actions remain exact. Malformed JSON stays literal.

Native event batches settle once per playback, not once per event. Interactive
single-step playback still settles each event. Synthetic V2 message records keep
their full-session rendering behavior.

## Restored V1 coverage

See [SNAPSHOT_TRIAGE.md](SNAPSHOT_TRIAGE.md) for per-fixture classifications,
reviewed updates, confirmed harness defects, and cases that must not be
regenerated blindly.

The V2 migration (`08f3d1c9`) replaced the V1 fixture loop with three observation
contract tests. Restoring the loop exposes differences that must be reviewed
before regenerating snapshots.

Batching restores the expected output for fixtures including `simple-session`,
`perf`, `planning`, `api-abort`, and `api-error`. Legacy `session_window` metadata
is a full-session viewport override, not part of an event-replay snapshot.

Remaining differences include:

- Header-only differences: missing mode falls back to `ASSISTANT` rather than
  `BUILD`; model names now appear in some headers.
- Display changes: relative tool paths, reference icons, generic tool input/result
  sections, and prompt spacing.
- Missing content requiring runtime investigation: diagnostics in `diagnostics`
  and permission fixtures; selection context in `selection` and `cursor_data`;
  child-task output in `explore`; text in `part-before-message-delta`.
- Mention extmarks missing from `mentions-with-ranges` and `diff`.
- Revert/redo differences also affect actions and extmark positions.

Do not regenerate all expected files to hide these failures. Review display
changes separately from missing content and protocol behavior.
