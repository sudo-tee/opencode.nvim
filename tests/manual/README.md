# Manual Testing Tools

This directory contains manual testing tools for visual inspection and debugging.

## Streaming Renderer Replay

Replay captured event data to visually test the streaming renderer.

### Usage

```bash
./tests/manual/run_replay.sh
```

Or manually:

```bash
nvim -u tests/manual/init_replay.lua -c "lua require('tests.manual.streaming_renderer_replay').start()"
```

### Available Commands

Once loaded, you can use these commands in Neovim:

- `:ReplayNext` - Replay the next event in sequence
- `:ReplayAll [ms]` - Auto-replay all events with optional delay in milliseconds (default: 100ms)
- `:ReplayStop` - Stop auto-replay
- `:ReplayReset` - Reset to the beginning (clears buffer and resets event index)
- `:ReplayStatus` - Show current replay status

### Example Workflow

1. Start the replay test: `./tests/manual/run_replay.sh`
2. Step through events one at a time: `:ReplayNext`
3. Or auto-replay all: `:ReplayAll 200` (200ms delay between events)
4. Reset and try again: `:ReplayReset`

### Event Data

Events are loaded from `tests/data/simple-session.json`. This file contains captured
events from a real session that can be replayed to test the streaming renderer behavior.

### Adding New Event Data

To capture new event data for testing:

1. Run OpenCode with event logging enabled
2. Copy the event stream JSON output
3. Save to a new file in `tests/data/`
4. Modify `streaming_renderer_replay.lua` to load your new data file

### Debugging Tips

- Watch the buffer updates in real-time with `:ReplayAll 500` (slower replay)
- Use `:ReplayNext` to step through problematic events
- Check `:messages` to see event notifications and any errors
- Inspect `state.messages` with `:lua vim.print(require('opencode.state').messages)`
