# Quick Start: Streaming Renderer Replay

## Preview V2 message formatters

From the repository root, start the existing replay UI:

```bash
./tests/manual/run_replay.sh
```

Then load and replay the JSON fixture:

```vim
:ReplayLoad tests/data/v2/formatters.json
:ReplayAll
```

Use `:ReplayNext` to step through examples, `:ReplayFullSession` to render all
messages immediately, and `:ReplaySave` to write `formatters.expected.json`.

Replay also works when started from an already configured Neovim: the harness
pins its mock connection so background discovery and health checks cannot send
fixture session IDs to a real server. Use `:ReplayExit` to close replay and
restore normal connection handling. `:ReplayStop` only stops playback.

Examples cover system text, loaded skills, running and exited shells (including
truncated output and nonzero exit codes), completed/running/failed compaction,
and directory changes with and without a previous location.

Run the renderer snapshot tests:

```bash
./run_tests.sh -t tests/replay/formatter_snapshot_spec.lua
```

Focused fixtures are `tests/data/v2/system-skill.json`, `shell.json`,
`compaction.json`, and `location-switched.json`. Each has its own
`.expected.json` output containing buffer lines, normalized extmarks, actions,
and viewport metadata.

These files use harness-only `replay.v2.message` records containing native V2
message snapshots in `properties.info`. They are not server SSE events: native
V2 system/skill/shell/compaction messages are currently normalized from message
snapshots. Repeated message IDs replace earlier snapshots during replay.

After intentional formatter changes, regenerate and review snapshot diffs:

```bash
env -u VIM -u VIMRUNTIME ./tests/manual/regenerate_expected.sh v2/formatters.json
```

## Run the visual replay test

```bash
# from the repository root
./tests/manual/run_replay.sh
```

## Once Neovim opens

You'll see the OpenCode UI with an empty output buffer.

### Step through events manually:
```vim
:ReplayNext
:ReplayNext
:ReplayNext
```

### Auto-replay all events (100ms between each):
```vim
:ReplayAll
```

### Auto-replay with custom delay (500ms):
```vim
:ReplayAll 500
```

### Stop auto-replay:
```vim
:ReplayStop
```

### Reset everything and start over:
```vim
:ReplayReset
```

### Check status:
```vim
:ReplayStatus
```

## What you should see

As you replay events, you'll see:
- User message appear with its parts
- Assistant message header appear
- Text streaming in (part updates)
- Step markers (step-start, step-finish)
- Real-time buffer updates as parts are added/modified

## Event sequence in simple-session.json

1. User message created
2. User message part (text: "only answer the following, nothing else:\n\n1")
3. User message parts (synthetic tool call + file content)
4. User message part (file attachment)
5. Assistant message created
6. Assistant step-start part
7. Assistant text part created (streaming: "1")
8. Assistant text part updated (final: "1")
9. Assistant step-finish part (with token counts)
10. Assistant message updated (3 times with final token counts)

## Debugging tips

- Watch `:messages` for event notifications
- Use `:lua vim.print(require('opencode.state').messages)` to inspect state
- Use `:ReplayNext` to step through problematic transitions
- Use slower replay (`:ReplayAll 1000`) to see updates clearly
