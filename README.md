# opencode.nvim

A Neovim frontend for [OpenCode](https://opencode.ai). Chat with the agent in a
side panel, send it files, selections, and diagnostics, and review its edits
without leaving the editor.

<div align="center">

![OpenCode chat panel beside a code buffer](https://github.com/user-attachments/assets/42da57f3-86b6-4409-b612-12c31fb1873f)
</div>

## Features

- Chat panel with separate input and output buffers, prompt history, and
  Markdown rendering.
- Context from the current file, visual selections, `@` file mentions,
  diagnostics, and clipboard images.
- Multiple sessions, each in its own panel tab, plus a session picker and
  timeline with undo and fork.
- Session diff review with inline comments that go into your next prompt
  (OpenCode V2).
- Quick chat for one-off edits on the current line or selection (experimental).

Works with OpenCode V1 and V2 servers; the protocol is detected automatically.
The `v1` branch keeps the old plugin code and is not needed for a V1 server.
See [Compatibility](docs/compatibility.md).

## Install

Requires Neovim 0.10.3 or later and the `opencode` CLI on your `PATH`, with a
provider already connected (run `opencode` and use `/connect`).

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
return {
  'sudo-tee/opencode.nvim',
  dependencies = {
    {
      'MeanderingProgrammer/render-markdown.nvim',
      opts = {
        anti_conceal = { enabled = false },
        file_types = { 'markdown', 'opencode_output' },
      },
      ft = { 'markdown', 'opencode_output' },
    },
  },
  opts = {},
}
```

With another plugin manager, install the plugin and call
`require('opencode').setup({})`. Then run `:checkhealth opencode`.

## Quick start

1. Open a file and press `<leader>oi`. The prompt opens in insert mode.
2. Type a request, for example "Add a test for the empty-list case".
3. Press `<Esc>`, then `<CR>` to send.
4. On V2, press `<leader>od` to review what the agent changed.

[Getting started](docs/getting-started.md) covers the same steps in more
detail, plus pickers and completion. Inside Neovim, see `:help opencode.nvim`.

## Where to go next

| I want to…                            | Read                                                                              |
| ------------------------------------- | --------------------------------------------------------------------------------- |
| Learn the everyday workflow           | [Usage](docs/usage.md)                                                            |
| Control what the agent sees           | [Context](docs/context.md)                                                        |
| Review changes and send feedback      | [Reviewing changes](docs/review.md)                                               |
| Adjust windows, keys, or integrations | [Configuration](docs/configuration.md)                                            |
| Connect to another server             | [Servers](docs/servers.md)                                                        |
| Write mappings or automation          | [Commands and Lua API](docs/reference.md), [Hooks and events](docs/extensions.md) |
| Fix a setup problem                   | [Troubleshooting](docs/troubleshooting.md)                                        |
| Contribute code or documentation      | [Contributing](CONTRIBUTING.md)                                                   |

## Credits

Based on [goose.nvim](https://github.com/azorng/goose.nvim) by
[azorng](https://github.com/azorng). The original code was copied to preserve
its Git history rather than using a GitHub fork.

If you find the plugin useful, you can [support its development](https://www.buymeacoffee.com/sudo.tee).
