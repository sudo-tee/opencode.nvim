# Getting started

[Documentation](README.md) / Getting started

This page gets you from install to a first answer. Customization comes later.

## Before installing

- **Neovim** 0.10.3 or later. CI runs 0.10.3, 0.11.4, and nightly.
- **OpenCode CLI:** install from the [OpenCode V2 guide](https://opencode.ai/v2/docs/)
  and make sure `opencode` is on the `PATH` Neovim sees. V1 also works; see
  [Compatibility](compatibility.md).
- **A connected provider:** run `opencode` in your project, use `/connect`, and
  send one prompt there. Providers, models, and agents are configured in
  OpenCode, not in this plugin.

Inside Neovim, check that the executable is visible:

```vim
:echo executable('opencode')
```

The result should be `1`. If your binary has another name or location, set
`opencode_executable` in the [plugin configuration](configuration.md).

## Install with lazy.nvim

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

`opts = {}` calls the plugin's setup function. With another manager, install
the plugin and call this once from your configuration:

```lua
require('opencode').setup({})
```

## Check your installation

After installing and loading the plugin, run:

```vim
:checkhealth opencode
```

It checks the CLI, the server connection and credentials, your configuration,
optional integrations, and file finder tools. Fix any errors before going on.
Warnings about missing optional plugins are fine; the plugin falls back to
built-in pickers and completion.

![OpenCode health report showing CLI, server, configuration, and integration checks](https://github.com/user-attachments/assets/72eaf1a1-5d66-4932-a1ae-ecc91872e99d)

## Optional integrations

None of these are required. The plugin uses whichever ones you already have.

| Purpose | Choices |
| --- | --- |
| Prompt completion | [blink.cmp](https://github.com/saghen/blink.cmp), [nvim-cmp](https://github.com/hrsh7th/nvim-cmp), built-in completion |
| File and session pickers | [Snacks](https://github.com/folke/snacks.nvim), [Telescope](https://github.com/nvim-telescope/telescope.nvim), [fzf-lua](https://github.com/ibhagwan/fzf-lua), [mini.pick](https://github.com/nvim-mini/mini.pick), `vim.ui.select` |
| UI glyphs | A [Nerd Font](https://www.nerdfonts.com/), or the `text` icon preset |

If you have more than one picker installed, choose one with `preferred_picker`.
With `mini.pick` you cannot select several items at once, for example when
deleting sessions.

## Send your first prompt

1. Open Neovim in your project and focus a code buffer.
2. Press `<leader>oi`. The input opens in insert mode.
3. Type “Explain this function and suggest a test for its edge cases.”
4. Press `<Esc>` to enter normal mode, then `<CR>` to submit.
5. Read the response. `<Tab>` in normal mode moves between input and output;
   `<leader>ot` moves between the panel and your last editor window.

`<Esc>` in normal mode closes the panel. `<S-CR>` sends straight from insert
mode, but some terminals send it as plain `<CR>`.

The current file is sent with the prompt by default. Type `#` in insert mode to
see and toggle what will be sent. If you work with files that must not leave
your machine, read [Context](context.md) first.

![Input context completion menu with current file, diagnostics, and a selection](https://github.com/user-attachments/assets/1f36af7e-3ddd-4419-999e-0bff4941b3a0)

## Try a selection next

Select a few lines in visual mode and press `<leader>oy`, then ask about that
code. `<leader>oY` pastes the selection into the prompt as a code block
instead.

After the agent edits a file on V2, `<leader>od` opens the diff.
[Reviewing changes](review.md) shows how to comment on a line and send the
comments back.

Next: [Usage](usage.md), [Configuration](configuration.md), or
[Troubleshooting](troubleshooting.md) if something did not work.
