# AGENTS.md (ui)

This directory owns the rendered conversation UI and the interactive targets drawn on top of assistant text.

## Reference target model

The stable chain is:

```text
assistant text
  -> reference_parser: positioned mention spans
  -> reference_facts: current-session refs + current executable file list
  -> formatter/render: screen-coordinate file and symbol targets
  -> navigation: execute the current RenderState target only
```

`reference_parser` only identifies text spans. It does not prove that a file exists. It must keep separate non-overlapping mentions even when they point to the same path. Path-level dedupe belongs only to picker-style file lists.

`reference_facts` is the maintained projection from current session messages. It owns two facts: current refs from assistant text and tool file-path facts, and the current executable file list derived from those refs. A file is executable when the referenced path currently exists on disk. This file list is the authority for rendering file affordances.

`formatter` must not parse assistant text or scan session messages. It consumes `context.current_refs` and `context.current_files`. A mention becomes an icon, highlight, and `RenderState` file target only when its path is present in `current_files`. A missing file mention stays ordinary text.

Symbol targets are bounded by the same file list. During a render cycle, `symbol_snapshot.new_cycle()` may reuse per-file Tree-sitter work inside that cycle. Symbol truth must not become long-lived UI state.

`navigation` consumes `RenderState` targets. It must not rediscover targets from the output buffer text. Keypress executes the target that render already produced; it is not a target lifecycle or refresh boundary.

Assistant message updates maintain `reference_facts` incrementally. New reference mentions extend the current refs and rebuild the executable file list before the affected rendered text parts are formatted.

`file.edited`, `file.watcher.updated`, and local buffer file lifecycle events are render invalidation boundaries. Local writes, buffer renames, buffer unloads, shell-change notifications, server file edits, and watcher add/change/unlink events can change executable files and symbol truth without changing assistant text. They refresh the reference file list and dirty currently rendered assistant text parts. The next render recreates or removes affordances through the same path: current refs, current file list, current Tree-sitter snapshot, formatter output.

This invalidation is limited to parts already in `RenderState`. Lazy-rendered history that is not in the output buffer waits for its normal render path. In normal edits the reference file list often stays the same; only symbol truth changes, so the next render reuses the same reference files and a fresh per-render Tree-sitter cycle.

## Expected failure diagnosis

If a visible path does not jump, inspect in this order:

```text
cursor position
  -> renderer.get_target_at_position(line, col)
  -> reference_facts.current_files()
  -> formatter context for that render
  -> navigation result
```

If `reference_facts.current_refs()` contains a mention but `renderer.get_target_at_position()` is nil, the problem is render projection or file-list membership.

If `renderer.get_target_at_position()` returns a target but jump fails, the problem is keypress-time execution or a missing edit invalidation event. Keypress must not patch the rendered state; fix the save/edit invalidation path.

If a nonexistent file has an icon or highlight, the bug is in render projection. Do not add cwd/root fallback code in `formatter`; fix the file list or the mention source.

## Editing rule

Prefer removing duplicate derivations over adding recovery paths. The UI should have one path from facts to rendered targets, and one path from rendered targets to execution.

Do not add a second resolver layer, compatibility shim, screen-text scanner, or root fallback to hide a broken file list.

## Regression commands

- `./run_tests.sh -t tests/unit/reference_facts_spec.lua`
- `./run_tests.sh -t tests/unit/formatter_spec.lua`
- `./run_tests.sh -t tests/unit/navigation_spec.lua`
- `./run_tests.sh -t tests/unit/renderer_targets_spec.lua`
- `./run_tests.sh -t tests/replay/renderer_spec.lua`
