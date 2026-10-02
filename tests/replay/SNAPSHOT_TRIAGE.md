# Restored V1 snapshot triage

The restored suite initially had 30 failures after batching and ignoring legacy
full-session viewport metadata. These failures are not all stale snapshots.

## Fixes made during triage

- **Replay harness bug:** V1 envelopes used the UI's active-session directory.
  After a valid `session.updated`, observation facts had the new directory while
  UI state still had the old directory. Later events in the batch were dropped.
  Envelopes now use the observation's current session location. A regression test
  covers `question-multiple-choices`.
- **12 reviewed header updates:** only agent/model header text changed. Buffer
  lines, actions, extmark positions, and non-header extmark properties matched.
  No missing-content expectations were removed.
- **V1 queued-message regression fixed:** new user input received during running
  or retrying execution gets a protocol-owned queue fact. Message updates and
  snapshot refreshes preserve it; a linked assistant reply clears it. Header
  reconciliation now tracks that fact and renders `QUEUED`. The queue snapshot
  retains its badge; only its unrelated missing-agent fallback changed to
  `ASSISTANT`.
- **Legacy V1 context decoding fixed:** validated synthetic JSON declarations map
  to the same editor-context facts as current metadata. Raw Neovim diagnostics
  become neutral diagnostics with one-based positions. Metadata stays authoritative;
  ordinary synthetic text is unchanged. Selection/cursor borders and hint severity
  rendering are covered by regressions. Remaining cosmetic differences were
  reviewed separately; no source captures or missing-context expectations changed.

## Regeneration-only changes

| Fixture | Evidence | Status |
| --- | --- | --- |
| `message-removal` | Assistant facts have no agent/mode; current header correctly says `ASSISTANT`, not invented `BUILD`. | Updated |
| `multiple-messages-synthetic` | Same missing-agent fallback; no content/action changes. | Updated |
| `provider-overloaded-status` | User model is supplied by the fixture and now appears in its header. | Updated |
| `permission-ask-new-deny` | Model header only; denial output/actions unchanged. | Updated |
| `question-ask` | Model header only; question output/actions unchanged. | Updated |
| `question-ask-other` | Model header only; question output/actions unchanged. | Updated |
| `question-ask-replied` | Model header only; answer output/actions unchanged. | Updated |
| `multiple-question-ask` | Model header only; stacked questions/actions unchanged. | Updated |
| `multiple-question-ask-reply-all` | Model header only; answered questions/actions unchanged. | Updated |
| `question-multiple-choices` | After fixing replay directory routing, only model header differs. | Updated |
| `question-multiple-choices-answered` | After fixing replay directory routing, only model header differs. | Updated |
| `question-multiple-other` | After fixing replay directory routing, only model header differs. | Updated |
| `redo-all` | Buffer diff contains only absolute-to-relative tool paths; actions match. | Updated |
| `tool-invalid` | Generic tool formatter adds Input/Result sections; existing error remains. | Regenerated |

## Bugs or compatibility regressions: do not regenerate missing content

| Fixture | Evidence / next fix |
| --- | --- |
| `queue` | Fixed: restored V1 queue projection, header badge, and invalidation when an assistant consumes the user. Regression tests cover busy/retry/idle, metadata updates, snapshot refreshes, and linked replies. |
| `selection` | Fixed: both saved selections render again. Snapshot changed only to remove one duplicate border extmark; visible border rows, text, and actions match. |
| `cursor_data` | Fixed: saved cursor excerpt renders; existing snapshot passes unchanged. |
| `diagnostics` | Fixed: raw Neovim diagnostic records map to neutral facts; summary restored. Snapshot changed only for two relative tool paths. |
| `permission-ask-new` | Fixed: legacy diagnostic summary restored. Snapshot changed only for user model header text. |
| `permission-ask-new-approve` | Fixed: same restored diagnostics; only user model header expectation updated. |
| `permission-prompt` | Capture uses historical `permission.updated` (`type`, `pattern`, `callID`), whereas current adapter accepts the newer permission contract. Missing prompt is a compatibility gap, not cosmetic drift. |
| `shifting-and-multiple-perms` | Same unsupported historical permission events remove all prompts; added reference icon is independently cosmetic. |
| `revert` | Historical `session.updated` lacks fields required by current `session_shape` (notably `slug`). Revert facts never reach rendering, so reverted messages remain visible. Resolve wire-version compatibility before changing expected output. |
| `redo-once` | Same rejected historical session updates; revert summary disappears and reverted conversation remains visible. Relative tool paths are independently cosmetic. |

Compatibility regressions above reproduce with the historical wire payloads.
They do **not** prove that a current V1 1.18 server sends the rejected shapes.
Fixes should explicitly map supported historical forms at the protocol boundary,
not relax strict current contracts or add UI guesses.

## Fixture/harness defects and unresolved cases

| Fixture | Finding / next step |
| --- | --- |
| `apply-patch` | Synthetic message facts omit required `time.created`; session fact also omits required identity fields. Adapter rejects messages, so no patch can render. Repair synthetic fixture, then reassess formatter diff. |
| `diff` | File mention declares offsets `0..13`, but `@diff-test.txt` occurs at byte 39. Strict mention validation correctly rejects it. Correct source range before refreshing highlight expectation. |
| `mentions-with-ranges` | Both recorded end offsets exclude the last character of their declared `value`. Current contract uses exclusive UTF-16 ends; slices do not equal the mention values. Establish/migrate legacy offset convention, not a guessed UI highlight. |
| `part-before-message-delta` | Delta arrives before message and without any `message.part.updated` establishing that part. Adapter deliberately requires an identified text/reasoning part. Define whether this synthetic ordering should be supported through buffering/rehydration, or repair fixture. Do not fabricate native part facts. |
| `explore` | Child tool summaries disappear. Replay mocks always return empty child/message snapshots; batched delivery can precede child-observation subscription. Reproduce with proper child bootstrap snapshots before blaming runtime task renderer or regenerating summaries away. |
| `mcp-tool` | Final first-tool update explicitly replaces `input.thought` with `input = {}`. Old expected output retains earlier thought; current output shows final result. Second thought remains. Determine whether fixture intends a partial tool update or authoritative final state; generic Result sections are independently expected. |

## Recommended order

1. Keep the directory-routing regression test and reviewed header updates.
2. Repair invalid synthetic facts/ranges and model child bootstrap accurately.
3. Restore queued-message display and decide historical V1 compatibility scope.
4. Add narrow regressions for preserved selection, diagnostics, permission and
   revert behavior before refreshing their cosmetic snapshot differences.
5. Regenerate only reviewed remaining display changes. Never make the suite green
   by deleting missing-content expectations.
