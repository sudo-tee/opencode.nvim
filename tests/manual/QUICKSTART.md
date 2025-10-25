# Quick Start: Streaming Renderer Replay

## Run the visual replay test

```bash
cd /Users/cam/Dev/neovim-dev/opencode.nvim
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
