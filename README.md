# 🤖 opencode.nvim

<div align="center">
  <img src="https://opencode.ai/_astro/logo-dark.NCybiIc5.svg" alt="Opencode logo" width="30%" />
</div>

> neovim integration with opencode - work with a powerful AI agent without leaving your editor

<div align="center">

![Neovim](https://img.shields.io/badge/NeoVim-%2357A143.svg?&style=for-the-badge&logo=neovim&logoColor=white)
[![GitHub stars](https://img.shields.io/github/stars/sudo-tee/opencode.nvim?style=for-the-badge)](https://github.com/sudo-tee/opencode.nvim/stargazers)
![Last Commit](https://img.shields.io/github/last-commit/sudo-tee/opencode.nvim?style=for-the-badge)

</div>

## 🙏 Acknowledgements

This plugin is a fork of the original [goose.nvim](https://github.com/azorng/goose.nvim) plugin by [azorng](https://github.com/azorng/)
For git history purposes the original code is copied instead of just forked.

## ✨ Description

This plugin provides a bridge between neovim and the [opencode](https://github.com/sst/opencode) AI agent, creating a chat interface while capturing editor context (current file, selections) to enhance your prompts. It maintains persistent sessions tied to your workspace, allowing for continuous conversations with the AI assistant similar to what tools like Cursor AI offer.

<div align="center">
  <img src="https://i.imgur.com/X6tFtc3.png" alt="Opencode.nvim interface" width="90%" />
  <img src="https://i.imgur.com/erqtPND.png" alt="Opencode.nvim help" width="90%" />
</div>

## 📑 Table of Contents

- [Requirements](#-requirements)
- [Installation](#-installation)
- [Configuration](#️-configuration)
- [Usage](#-usage)
- [Context](#-context)
- [Setting up opencode](#-setting-up-opencode)

## 📋 Requirements

- Opencode CLI installed and available (see [Setting up opencode](#-setting-up-opencode) below)

## 🚀 Installation

Install the plugin with your favorite package manager. See the [Configuration](#️-configuration) section below for customization options.

### With lazy.nvim

```lua
{
  "sudo-tee/opencode.nvim",
  config = function()
    require("opencode").setup({})
  end,
  dependencies = {
    "nvim-lua/plenary.nvim",
    {
      "MeanderingProgrammer/render-markdown.nvim",
      opts = {
        anti_conceal = { enabled = false },
        file_types = { 'markdown', 'opencode_output' },
      },
      ft = { 'markdown', 'Avante', 'copilot-chat', 'opencode_output' },
    }
  },
}
```

## ⚙️ Configuration

```lua
-- Default configuration with all available options
require('opencode').setup({
  prefered_picker = nil,                     -- 'telescope', 'fzf', 'mini.pick', 'snacks', if nil, it will use the best available picker
  default_global_keymaps = true,             -- If false, disables all default global keymaps
  default_mode = 'build',                    -- 'build' or 'plan' or any custom configured. @see [OpenCode Modes](https://opencode.ai/docs/modes/)
  keymap = {
    global = {
      toggle = '<leader>oa',                 -- Open opencode. Close if opened
      open_input = '<leader>oi',             -- Opens and focuses on input window on insert mode
      open_input_new_session = '<leader>oI', -- Opens and focuses on input window on insert mode. Creates a new session
      open_output = '<leader>oo',            -- Opens and focuses on output window
      toggle_focus = '<leader>ot',           -- Toggle focus between opencode and last window
      close = '<leader>oq',                  -- Close UI windows
      toggle_fullscreen = '<leader>of',      -- Toggle between normal and fullscreen mode
      select_session = '<leader>os',         -- Select and load a opencode session
      configure_provider = '<leader>op',     -- Quick provider and model switch from predefined list
      diff_open = '<leader>od',              -- Opens a diff tab of a modified file since the last opencode prompt
      diff_next = '<leader>o]',              -- Navigate to next file diff
      diff_prev = '<leader>o[',              -- Navigate to previous file diff
      diff_close = '<leader>oc',             -- Close diff view tab and return to normal editing
      diff_revert_all = '<leader>ora',       -- Revert all file changes since the last opencode prompt
      diff_revert_this = '<leader>ort',      -- Revert current file changes since the last opencode prompt
    },
    window = {
      submit = '<cr>',                     -- Submit prompt (normal mode)
      submit_insert = '<C-s>',             -- Submit prompt (insert mode)
      close = '<esc>',                     -- Close UI windows
      stop = '<C-c>',                      -- Stop opencode while it is running
      next_message = ']]',                 -- Navigate to next message in the conversation
      prev_message = '[[',                 -- Navigate to previous message in the conversation
      mention_file = '@',                  -- Pick a file and add to context. See File Mentions section
      toggle_pane = '<tab>',               -- Toggle between input and output panes
      prev_prompt_history = '<up>',        -- Navigate to previous prompt in history
      next_prompt_history = '<down>',      -- Navigate to next prompt in history
      switch_mode = '<M-m>',               -- Switch between modes (build/plan)
      focus_input = '<C-i>',               -- Focus on input window and enter insert mode at the end of the input from the output window
      debug_messages = '<leader>oD',       -- Open raw message in new buffer for debugging
      debug_output = '<leader>oO',         -- Open raw output in new buffer for debugging
    }
  },
  ui = {
    floating = false,                      -- Use floating windows for input and output
    window_width = 0.40,                   -- Width as percentage of editor width
    input_height = 0.15,                   -- Input height as percentage of window height
    fullscreen = false,                    -- Start in fullscreen mode (default: false)
    layout = "right",                      -- Options: "center" or "right"
    floating_height = 0.8,                 -- Height as percentage of editor height for "center" layout
    display_model = true,                  -- Display model name on top winbar
    window_highlight = "Normal:OpencodeBackground,FloatBorder:OpencodeBorder", -- Highlight group for the opencode window
  },
  debug = {
    enabled = false,                       -- Enable debug messages in the output window
  },
})
```

## 🧰 Usage

### Available Actions

The plugin provides the following actions that can be triggered via keymaps, commands, or the Lua API:

| Action                                           | Default keymap | Command                           | API Function                                        |
| ------------------------------------------------ | -------------- | --------------------------------- | --------------------------------------------------- |
| Open opencode. Close if opened                   | `<leader>og`   | `:Opencode`                       | `require('opencode.api').toggle()`                  |
| Open input window (current session)              | `<leader>oi`   | `:OpencodeOpenInput`              | `require('opencode.api').open_input()`              |
| Open input window (new session)                  | `<leader>oI`   | `:OpencodeOpenInputNewSession`    | `require('opencode.api').open_input_new_session()`  |
| Open output window                               | `<leader>oo`   | `:OpencodeOpenOutput`             | `require('opencode.api').open_output()`             |
| Toggle focus opencode / last window              | `<leader>ot`   | `:OpencodeToggleFocus`            | `require('opencode.api').toggle_focus()`            |
| Close UI windows                                 | `<leader>oq`   | `:OpencodeClose`                  | `require('opencode.api').close()`                   |
| Toggle fullscreen mode                           | `<leader>of`   | `:OpencodeToggleFullscreen`       | `require('opencode.api').toggle_fullscreen()`       |
| Select and load session                          | `<leader>os`   | `:OpencodeSelectSession`          | `require('opencode.api').select_session()`          |
| Configure provider and model                     | `<leader>op`   | `:OpencodeConfigureProvider`      | `require('opencode.api').configure_provider()`      |
| Open diff view of changes                        | `<leader>od`   | `:OpencodeDiff`                   | `require('opencode.api').diff_open()`               |
| Navigate to next file diff                       | `<leader>o]`   | `:OpencodeDiffNext`               | `require('opencode.api').diff_next()`               |
| Navigate to previous file diff                   | `<leader>o[`   | `:OpencodeDiffPrev`               | `require('opencode.api').diff_prev()`               |
| Close diff view tab                              | `<leader>oc`   | `:OpencodeDiffClose`              | `require('opencode.api').diff_close()`              |
| Revert all file changes                          | `<leader>ora`  | `:OpencodeRevertAll`              | `require('opencode.api').diff_revert_all()`         |
| Revert current file changes                      | `<leader>ort`  | `:OpencodeRevertThis`             | `require('opencode.api').diff_revert_this()`        |
| Initialize/update AGENTS.md file                 | -              | `:OpencodeInit`                   | `require('opencode.api').initialize()`              |
| Run prompt (continue session)                    | -              | `:OpencodeRun <prompt>`           | `require('opencode.api').run("prompt")`             |
| Run prompt (new session)                         | -              | `:OpencodeRunNewSession <prompt>` | `require('opencode.api').run_new_session("prompt")` |
| Open config file                                 | -              | `:OpencodeConfigFile`             | `require('opencode.api').open_configuration_file()` |
| Stop opencode while it is running                | `<C-c>`        | `:OpencodeStop`                   | `require('opencode.api').stop()`                    |
| Set mode to Build                                | -              | `:OpencodeModeBuild`              | `require('opencode.api').mode_build()`              |
| Set mode to Plan                                 | -              | `:OpencodeModePlan`               | `require('opencode.api').mode_plan()`               |
| Select and switch mode                           | -              | `:OpencodeModeSelect`             | `require('opencode.api').select_mode()`             |
| Display list of availale mcp servers             | -              | `:OpencodeMCP`                    | `require('opencode.api').list_mcp_servers()`        |
| [Pick a file and add to context](#file-mentions) | `@`            | -                                 | -                                                   |
| Navigate to next message                         | `]]`           | -                                 | -                                                   |
| Navigate to previous message                     | `[[`           | -                                 | -                                                   |
| Navigate to previous prompt in history           | `<up>`         | -                                 | `require('opencode.api').prev_history()`            |
| Navigate to next prompt in history               | `<down>`       | -                                 | `require('opencode.api').next_history()`            |
| Toggle input/output panes                        | `<tab>`        | -                                 | -                                                   |

## 📝 Context

The following editor context is automatically captured and included in your conversations.

| Context Type    | Description                                        |
| --------------- | -------------------------------------------------- |
| Current file    | Path to the focused file before entering opencode  |
| Selected text   | Text and lines currently selected in visual mode   |
| Mentioned files | File info added through [mentions](#file-mentions) |
| Diagnostics     | Error diagnostics from the current file (if any)   |

<a id="file-mentions"></a>

### Adding more files to context through file mentions

You can reference files in your project directly in your conversations with Opencode. This is useful when you want to ask about or provide context about specific files. Type `@` in the input window to trigger the file picker.
Supported pickers include [`fzf-lua`](https://github.com/ibhagwan/fzf-lua), [`telescope`](https://github.com/nvim-telescope/telescope.nvim), [`mini.pick`](https://github.com/echasnovski/mini.nvim/blob/main/readmes/mini-pick.md), [`snacks`](https://github.com/folke/snacks.nvim/blob/main/docs/picker.md)

## 🔄 Modes

Opencode provides two built-in modes and supports custom ones:

### Built-in Modes

- **Build** (default): Full development mode with all tools enabled for making code changes
- **Plan**: Restricted mode for planning and analysis without making file changes. Useful for code review and understanding code without modifications

### Switching Modes

Press `<M-m>` (Alt+M) in the input window to switch between modes during a session.

### Custom Modes

You can create custom modes through your opencode config file. Each mode can have its own:

- Model configuration
- Custom prompt
- Enabled/disabled tools
- And more

See [Opencode Modes Documentation](https://opencode.ai/docs/modes/) for full configuration options.

### Highlight Groups

The plugin defines several highlight groups that can be customized to match your colorscheme:

- `OpencodeBorder`: Border color for Opencode windows (default: #616161)
- `OpencodeBackground`: Background color for Opencode windows (linked to `Normal`)
- `OpencodeSessionDescription`: Session description text color (linked to `Comment`)
- `OpencodeMention`: Highlight for @file mentions (linked to `Special`)
- `OpencodeToolBorder`: Border color for tool execution blocks (default: #3b4261)
- `OpencodeMessageRoleAssistant`: Assistant message highlight (linked to `Added`)
- `OpencodeMessageRoleUser`: User message highlight (linked to `Question`)
- `OpencodeDiffAdd`: Highlight for added line in diffs (default: #2B3328)
- `OpencodeDiffDelete`: Highlight for deleted line in diffs (default: #43242B)
- `OpencodeModePlan`: Mode indicator in winbar for Plan mode (default: #61AFEF background)
- `OpencodeModeBuild`: Mode indicator in winbar for Build mode (default: #616161 background)
- `OpencodeModeCustom`: Mode indicator in winbar for custom modes (default: #3b4261 background)

## 🔧 Setting up Opencode

If you're new to opencode:

1. **What is Opencode?**

   - Opencode is an AI coding agent built for the terminal
   - It offers powerful AI assistance with extensible configurations such as LLMs and MCP servers

2. **Installation:**

   - Visit [Install Opencode](https://opencode.ai/docs/#install) for installation and configuration instructions
   - Ensure the `opencode` command is available after installation

3. **Configuration:**
   - Run `opencode auth login` to set up your LLM provider
   - Configure your preferred LLM provider and model in the `~/.config/opencode/config.json` file
