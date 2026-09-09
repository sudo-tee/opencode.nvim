# Runtime and maintainability audit

This audit reviewed transport, event batching and subscriptions, timers, file completion,
promise settlement, history persistence, snapshot/review commands, and renderer update
primitives. It includes targeted fixes and regression tests. It is not a guarantee that
every runtime or platform combination is free of defects.

## Fixed

| Priority | Finding | Change |
| --- | --- | --- |
| High | File completion synchronously waited for server responses and shell searches. Server errors prevented fallback; Lua also treats `executable()` returning `0` as true. | Yield through promises, catch failed searches, skip unavailable executables, and enforce the configured result limit. |
| High | Delayed server-ready callbacks could reconnect after stop; an old server's shutdown could close the replacement subscription. Buffered and late events could cross subscription boundaries. | Guard callbacks with lifecycle/subscription identities, check the current server, and clear pending batches and cached parts at subscription cleanup. |
| High | The server test suite passed fake PIDs to real process enumeration and signal functions. The first full run terminated with exit 143. | Stub both OS operations for server tests, including restoration after each test. The termination's precise cause was not independently proven. |
| Medium | Collapsing repeated part updates rescanned all intervening events, producing quadratic work. | Track the most recent permission-event index, preserving the existing permission ordering rule in constant time per update. |
| Medium | Streaming line extraction copied the remaining buffer for each line. | Scan by offset and retain the remaining suffix once per chunk. Extremely long, incomplete lines can still cause repeated concatenation across chunks. |
| Medium | HTTP parsing stopped at a proxy CONNECT or informational response, potentially reporting the wrong status and treating final headers as body text. | Consume preliminary header blocks and parse the final response; preserve bodies that happen to resemble HTTP headers. |
| Medium | A cleared throttle callback could consume a new batch before its own deadline. | Invalidate cancelled callbacks using a generation counter. |
| Medium | Queued timer ticks could run after stop/restart; an old tick could stop a replacement timer created inside the callback. | Check timer identity before invocation and before stopping. |
| Medium | A listener unsubscribing itself during event emission could cause the next listener to be skipped. | Iterate a snapshot of the listener list. |

## Measurements and verification

`./run_tests.sh`: **1,224 passed, zero failed**, including minimal, unit, and replay tests.
The sandboxed run could not create Neovim swap files; the successful complete run used
approved filesystem access. Targeted tests cover pending completion responses, fallback,
subscription replacement, timer restart, cancellation, HTTP headers, and stream boundaries.
Changed Lua files were formatted with the repository's StyLua configuration; `git diff --check` passed.

A synthetic benchmark compared the original and updated event manager in headless Neovim.
Each batch contained repeated full updates to one text part; event delivery was disabled
to isolate normalization and collapsing. Results are the median of five runs, with GC
before each run, on the audit machine:

| Updates per batch | Before | After |
| --- | ---: | ---: |
| 1,000 | 1.49 ms | 0.67 ms |
| 4,000 | 18.05 ms | 2.33 ms |
| 8,000 | 78.79 ms | 4.80 ms |

This demonstrates the removed quadratic scan. It is not an end-to-end rendering or typing
latency measurement. Live server, Windows shell, and large-repository interactive testing
remain useful follow-up validation.

## Remaining findings, in recommended order

1. **Addressed: history encoding and deletion.** New writes use JSON lines in `history.jsonl`,
   with legacy `history.txt` reading and migration on the first write. Existing ambiguous
   legacy records retain their previous interpretation; the legacy file remains intact.
   Deletion deduplicates indices and commits rewrites atomically without mutating the cache
   on failure. Regression tests cover round trips, migration, clear, duplicate indices and
   failed writes.
2. **Addressed: snapshot/review and API startup waits.** Snapshot APIs now return promises;
   revert operations resolve to `{ id, deleted_files }`. Callers await Git processes and
   picker choices, and command handlers return the complete promise chain. Operations capture
   their session/directory and serialize access to each snapshot index. Stale review results
   are ignored. API startup and version detection yield, with cancellation available before
   an event subscription starts. Real temporary Git repositories exercise revert and recovery;
   mocked delayed processes exercise concurrency and workspace switches. Checkout errors no
   longer imply that a file should be deleted, and diff previews preserve original bytes.
3. **Addressed: promise retention and falsy rejections.** Settlement clears both callback
   queues and the waiting coroutine list after scheduling consumers. Rejection has its own
   state flag, preserving `false` and `nil` rejection reasons consistently through chaining,
   `finally`, synchronous waiting and coroutine awaiting. Both early and late consumers have
   regression coverage.
4. **Architecture remains tightly coupled.** The required topology scanner reports **5 cycles**,
   a **largest strongly connected component of 41 modules**, **18 policy violations**, and
   **11 ungrouped modules**. The HEAD-to-worktree diff adds/removes zero dependency edges and
   introduces zero violations. Of the violations, 12 are capability-to-entry dependencies,
   4 entry-to-infrastructure, and 2 capability-to-dispatch. Prioritize renderer/formatter
   dependencies on permission/question windows and the `ui.ui` orchestration boundary.
   Expand scanner group coverage before using its totals as a comprehensive architecture gate.

The remaining findings above are based on source inspection, not newly added reproductions.
They are intentionally recorded separately from the tested fixes.

Scanner commands (install `scripts/dependency-topology/requirements.txt` first):

```sh
python3 scripts/dependency-topology/scan_topology.py scan --json
python3 scripts/dependency-topology/scan_topology.py diff --from HEAD --to worktree --json
```
