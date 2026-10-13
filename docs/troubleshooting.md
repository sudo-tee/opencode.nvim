# Troubleshooting

[Documentation](README.md) / Troubleshooting

Start by checking whether the problem is in the plugin or in OpenCode: send the
same small request from the OpenCode CLI, in the same project, with the same
model.

## Neovim cannot find OpenCode

```vim
:echo executable('opencode')
:echo exepath('opencode')
```

`0` means the CLI is not on Neovim's `PATH`. GUI launchers often get a different
`PATH` than your shell. Fix `PATH` or set `opencode_executable` to the full path,
then restart Neovim.

## The panel cannot connect

For the default V2 service:

```sh
opencode service status
opencode api get /api/info
```

If the service is unhealthy, run `opencode service restart`. This interrupts
every connected client. See
[OpenCode troubleshooting](https://opencode.ai/v2/docs/troubleshooting) for
more.

For an explicit server, check `server.url`, `port`, credentials, and that the
host is reachable from the machine running Neovim. `401`/`403` means the
credentials are wrong. `url` should not include the port. Raise
`server.timeout` only if the server really is slow to start.

## Completion

If completion pops up too often, see the
[quiet Blink recipe](recipes/quiet-blink.md).

## Output looks wrong or rendering is slow

Check that your Markdown renderer is enabled for the `opencode_output`
filetype and that the Treesitter Markdown parsers are installed. Missing glyphs
mean the font has no Nerd Font icons; set `ui.icons.preset = 'text'`.

To rule out the renderer, set `ui.output.rendering.on_data_rendered = false`
(any boolean turns off the renderer integration). For long conversations,
`ui.output.max_messages` limits how many messages render at first.

## A file jump uses the wrong path

With containers, remote hosts, or WSL, check `path_map` and
`reverse_path_map`; both directions must map to the same project files. Jumps
from a session diff land on the current file, so lines may be off if the file
changed since.

## Capture and export streamed events

Event capture is off by default. Captured events stay in memory until you
export them:

```lua
require('opencode').setup({
  debug = { capture_streamed_events = true },
})
```

Restart Neovim, reproduce the issue, then export:

```vim
:Opencode debug events
:Opencode debug events /tmp/opencode-events.json
```

Or from Lua: `require('opencode.api').debug_events('/tmp/opencode-events.json')`.

Without a filename the file is `data.json` in the current working directory.
Export before quitting; the capture is lost on exit. The JSON can be replayed
with the tools in [`tests/manual/README.md`](../tests/manual/README.md).
Captures include prompts and file contents, so redact them before sharing.

## Enable plugin logging

```lua
require('opencode').setup({
  logging = { enabled = true, level = 'debug' },
})
```

Restart Neovim and reproduce the issue. The log goes to
`vim.fn.stdpath('log') .. '/opencode.log'` unless `logging.outfile` is set.
`:Opencode debug log` (or `require('opencode.api').debug_log()`) opens it in the
current window. To print the path:

```vim
:lua print(require('opencode.log').get_path())
```

This prints `nil` when logging is disabled.

With `debug.enabled = true`, these keys work in the output window: `<leader>oD`
for raw message data, `<leader>oO` for raw output, and `<leader>oDs` for raw
session data.

## Reporting a bug

Open an [issue](https://github.com/sudo-tee/opencode.nvim/issues) with:

- Neovim version, OpenCode version, and plugin commit/branch.
- OS, terminal, plugin manager, and relevant picker/completion/renderer.
- How you connect: native service, explicit `server.url`, or a launcher.
- A minimal configuration and exact steps, expected result, and actual result.
- Whether the same request works in the CLI.
- Relevant redacted logs or a small screenshot/recording.

Remove passwords, authorization headers, URLs with credentials, private
prompts, and file contents from anything you attach. `<leader>oDu` copies the
server URL, which can include credentials.
