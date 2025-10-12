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

- `:ReplayLoad [file]` - Load event data file (default: tests/data/simple-session.json)
- `:ReplayNext` - Replay the next event in sequence
- `:ReplayAll [ms]` - Auto-replay all events with optional delay in milliseconds (default: 50ms)
- `:ReplayStop` - Stop auto-replay
- `:ReplayReset` - Reset to the beginning (clears buffer and resets event index)
- `:ReplayClear` - Clear output buffer without resetting event index
- `:ReplaySave [file]` - Save snapshot of current buffer state (auto-derives filename from loaded file). Used to generated expected files for unit tests
- `:ReplayStatus` - Show current replay status
- `:ReplayHeadless` - Enable headless mode (useful for an AI agent to see replays)

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

1. Set `capture_streamed_events = true` in your config
2. Use OpenCode normally to generate the events you want to capture
3. Call `:lua require('opencode.ui.debug_helper').save_captured_events('data.json')`
4. The captured events will be saved to `data.json` in the current directory
5. That data can then be loaded with `:ReplayLoad`

### Debugging Tips

- Watch the buffer updates in real-time with `:ReplayAll 500` (slower replay)
- Use `:ReplayNext` to step through problematic events
- Check `:messages` to see event notifications and any errors
- Inspect `state.messages` with `:lua vim.print(require('opencode.state').messages)`
