# 🤖 opencode.nvim

<div align="center">
  <img src="https://opencode.ai/_astro/logo-dark.NCybiIc5.svg" alt="Opencode logo" width="30%" />
</div>

> neovim frontend for opencode - a terminal-based AI coding agent

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

- [⚠️Caution](#caution)
- [Requirements](#-requirements)
- [Installation](#-installation)
- [Configuration](#️-configuration)
- [Usage](#-usage)
- [Context](#-context)
- [Contextual Actions for Snapshots](#-contextual-actions-for-snapshots)
- [Setting up opencode](#-setting-up-opencode)

## ⚠️Caution

This plugin is in early development and may have bugs and breaking changes. It is not recommended for production use yet. Please report any issues you encounter on the [GitHub repository](https://github.com/sudo-tee/opencode.nvim/issues).

[Opencode](https://github.com/sst/opencode) is also in early development and may have breaking changes. Ensure you are using a compatible version of the Opencode CLI (v0.4.2+ or more).

If your upgrade breaks the plugin, please open an issue or downgrade to the last working version.

## 📋 Requirements

- Opencode (v0.4.2+ or more) CLI installed and available (see [Setting up opencode](#-setting-up-opencode) below)

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
  prefered_picker = nil, -- 'telescope', 'fzf', 'mini.pick', 'snacks', if nil, it will use the best available picker
  default_global_keymaps = true, -- If false, disables all default global keymaps
  default_mode = 'build', -- 'build' or 'plan' or any custom configured. @see [OpenCode Agents](https://opencode.ai/docs/modes/)
  config_file_path = nil, -- Path to opencode configuration file if different from the default `~/.config/opencode/config.json` or `~/.config/opencode/opencode.json`
  keymap = {
    global = {
      toggle = '<leader>oa', -- Open opencode. Close if opened
      open_input = '<leader>oi', -- Opens and focuses on input window on insert mode
      open_input_new_session = '<leader>oI', -- Opens and focuses on input window on insert mode. Creates a new session
      open_output = '<leader>oo', -- Opens and focuses on output window
      toggle_focus = '<leader>ot', -- Toggle focus between opencode and last window
      close = '<leader>oq', -- Close UI windows
      select_session = '<leader>os', -- Select and load a opencode session
      configure_provider = '<leader>op', -- Quick provider and model switch from predefined list
      diff_open = '<leader>od', -- Opens a diff tab of a modified file since the last opencode prompt
      diff_next = '<leader>o]', -- Navigate to next file diff
      diff_prev = '<leader>o[', -- Navigate to previous file diff
      diff_close = '<leader>oc', -- Close diff view tab and return to normal editing
      diff_revert_all_last_prompt = '<leader>ora', -- Revert all file changes since the last opencode prompt
      diff_revert_this_last_prompt = '<leader>ort', -- Revert current file changes since the last opencode prompt
      diff_revert_all = '<leader>orA', -- Revert all file changes since the last opencode session
      diff_revert_this = '<leader>orT', -- Revert current file changes since the last opencode session
      swap_position = '<leader>ox', -- Swap Opencode pane left/right
    },
    window = {
      submit = '<cr>', -- Submit prompt (normal mode)
      submit_insert = '<C-s>', -- Submit prompt (insert mode)
      close = '<esc>', -- Close UI windows
      stop = '<C-c>', -- Stop opencode while it is running
      next_message = ']]', -- Navigate to next message in the conversation
      prev_message = '[[', -- Navigate to previous message in the conversation
      mention_file = '@', -- Pick a file and add to context. See File Mentions section
      slash_command = '/', -- Pick a command to run in the input window
      toggle_pane = '<tab>', -- Toggle between input and output panes
      prev_prompt_history = '<up>', -- Navigate to previous prompt in history
      next_prompt_history = '<down>', -- Navigate to next prompt in history
      switch_mode = '<M-m>', -- Switch between modes (build/plan)
      focus_input = '<C-i>', -- Focus on input window and enter insert mode at the end of the input from the output window
      debug_messages = '<leader>oD', -- Open raw message in new buffer for debugging
      debug_output = '<leader>oO', -- Open raw output in new buffer for debugging
    },
  },
  ui = {
    position = 'right', -- 'right' (default) or 'left'. Position of the UI split
    input_position = 'bottom', -- 'bottom' (default) or 'top'. Position of the input window
    window_width = 0.40, -- Width as percentage of editor width
    input_height = 0.15, -- Input height as percentage of window height
    display_model = true, -- Display model name on top winbar
    display_context_size = true, -- Display context size in the footer
    display_cost = true, -- Display cost in the footer
    window_highlight = 'Normal:OpencodeBackground,FloatBorder:OpencodeBorder', -- Highlight group for the opencode window
    icons = {
      preset = 'emoji', -- 'emoji' | 'text'. Choose UI icon style (default: 'emoji')
      overrides = {},   -- Optional per-key overrides, see section below
    },
    output = {
      tools = {
        show_output = true, -- Show tools output [diffs, cmd output, etc.] (default: true)
      },
    },
    input = {
      text = {
        wrap = false, -- Wraps text inside input window
      },
    },
  },
  context = {
    cursor_data = true, -- send cursor position and current line to opencode
    diagnostics = {
      info = false, -- Include diagnostics info in the context (default to false
      warn = true, -- Include diagnostics warnings in the context
      error = true, -- Include diagnostics errors in the context
    },
  },
  debug = {
    enabled = false, -- Enable debug messages in the output window
  },
})
```

### UI icons (disable emojis or customize)

By default, opencode.nvim uses emojis for icons in the UI. If you prefer a plain, emoji-free interface, you can switch to the `text` preset or override icons individually.

Minimal config to disable emojis everywhere:

```lua
require('opencode').setup({
  ui = {
    icons = {
      preset = 'text', -- switch all icons to text
    },
  },
})
```

Override specific icons while keeping the preset:

```lua
require('opencode').setup({
  ui = {
    icons = {
      preset = 'emoji',
      overrides = {
        header_user = '> U',
        header_assistant = 'AI',
        search = 'FIND',
        border = '|',
      },
    },
  },
})
```

Available icon keys (see implementation at lua/opencode/ui/icons.lua lines 7-29):

- header_user, header_assistant
- run, task, read, edit, write
- plan, search, web, list, tool
- snapshot, restore_point, restore_count, file
- status_on, status_off
- border, bullet

## 🧰 Usage

### Available Actions

The plugin provides the following actions that can be triggered via keymaps, commands, or the Lua API:

| Action                                           | Default keymap | Command                           | API Function                                             |
| ------------------------------------------------ | -------------- | --------------------------------- | -------------------------------------------------------- |
| Open opencode. Close if opened                   | `<leader>og`   | `:Opencode`                       | `require('opencode.api').toggle()`                       |
| Open input window (current session)              | `<leader>oi`   | `:OpencodeOpenInput`              | `require('opencode.api').open_input()`                   |
| Open input window (new session)                  | `<leader>oI`   | `:OpencodeOpenInputNewSession`    | `require('opencode.api').open_input_new_session()`       |
| Open output window                               | `<leader>oo`   | `:OpencodeOpenOutput`             | `require('opencode.api').open_output()`                  |
| Toggle focus opencode / last window              | `<leader>ot`   | `:OpencodeToggleFocus`            | `require('opencode.api').toggle_focus()`                 |
| Close UI windows                                 | `<leader>oq`   | `:OpencodeClose`                  | `require('opencode.api').close()`                        |
| Select and load session                          | `<leader>os`   | `:OpencodeSelectSession`          | `require('opencode.api').select_session()`               |
| Configure provider and model                     | `<leader>op`   | `:OpencodeConfigureProvider`      | `require('opencode.api').configure_provider()`           |
| Open diff view of changes                        | `<leader>od`   | `:OpencodeDiff`                   | `require('opencode.api').diff_open()`                    |
| Navigate to next file diff                       | `<leader>o]`   | `:OpencodeDiffNext`               | `require('opencode.api').diff_next()`                    |
| Navigate to previous file diff                   | `<leader>o[`   | `:OpencodeDiffPrev`               | `require('opencode.api').diff_prev()`                    |
| Close diff view tab                              | `<leader>oc`   | `:OpencodeDiffClose`              | `require('opencode.api').diff_close()`                   |
| Revert all file changes since last prompt        | `<leader>ora`  | `:OpencodeRevertAllLastPrompt`    | `require('opencode.api').diff_revert_all_last_prompt()`  |
| Revert current file changes last prompt          | `<leader>ort`  | `:OpencodeRevertAllLastPrompt`    | `require('opencode.api').diff_revert_this_last_prompt()` |
| Revert all file changes since last session       | `<leader>orA`  | `:OpencodeRevertAllLastSession`   | `require('opencode.api').diff_revert_all_last_prompt()`  |
| Revert current file changes last session         | `<leader>orT`  | `:OpencodeRevertAllLastSession`   | `require('opencode.api').diff_revert_this_last_prompt()` |
| Initialize/update AGENTS.md file                 | -              | `:OpencodeInit`                   | `require('opencode.api').initialize()`                   |
| Run prompt (continue session)                    | -              | `:OpencodeRun <prompt>`           | `require('opencode.api').run("prompt")`                  |
| Run prompt (new session)                         | -              | `:OpencodeRunNewSession <prompt>` | `require('opencode.api').run_new_session("prompt")`      |
| Open config file                                 | -              | `:OpencodeConfigFile`             | `require('opencode.api').open_configuration_file()`      |
| Stop opencode while it is running                | `<C-c>`        | `:OpencodeStop`                   | `require('opencode.api').stop()`                         |
| Set mode to Build                                | -              | `:OpencodeAgentBuild`             | `require('opencode.api').mode_build()`                   |
| Set mode to Plan                                 | -              | `:OpencodeAgentPlan`              | `require('opencode.api').mode_plan()`                    |
| Select and switch mode/agent                     | -              | `:OpencodeAgentSelect`            | `require('opencode.api').select_agent()`                 |
| Display list of availale mcp servers             | -              | `:OpencodeMCP`                    | `require('opencode.api').list_mcp_servers()`             |
| Run user commands                                | -              | `:RunUserCommand`                 | `require('opencode.api').run_user_command()`             |
| [Pick a file and add to context](#file-mentions) | `@`            | -                                 | -                                                        |
| Navigate to next message                         | `]]`           | -                                 | -                                                        |
| Navigate to previous message                     | `[[`           | -                                 | -                                                        |
| Navigate to previous prompt in history           | `<up>`         | -                                 | `require('opencode.api').prev_history()`                 |
| Navigate to next prompt in history               | `<down>`       | -                                 | `require('opencode.api').next_history()`                 |
| Toggle input/output panes                        | `<tab>`        | -                                 | -                                                        |
| Swap Opencode pane left/right                    | `<leader>ox`   | `:OpencodeSwapPosition`           | `require('opencode.api').swap_position()`                |

## 📝 Context

The following editor context is automatically captured and included in your conversations.

| Context Type    | Description                                          |
| --------------- | ---------------------------------------------------- |
| Current file    | Path to the focused file before entering opencode    |
| Selected text   | Text and lines currently selected in visual mode     |
| Mentioned files | File info added through [mentions](#file-mentions)   |
| Diagnostics     | Diagnostics from the current file (if any)           |
| Cursor position | Current cursor position and line content in the file |

<a id="file-mentions"></a>

### Adding more files to context through file mentions

You can reference files in your project directly in your conversations with Opencode. This is useful when you want to ask about or provide context about specific files. Type `@` in the input window to trigger the file picker.
Supported pickers include [`fzf-lua`](https://github.com/ibhagwan/fzf-lua), [`telescope`](https://github.com/nvim-telescope/telescope.nvim), [`mini.pick`](https://github.com/echasnovski/mini.nvim/blob/main/readmes/mini-pick.md), [`snacks`](https://github.com/folke/snacks.nvim/blob/main/docs/picker.md)

## 🔄 Agents

Opencode provides two built-in agents and supports custom ones:

### Built-in Agents

- **Build** (default): Full development agent with all tools enabled for making code changes
- **Plan**: Restricted agent for planning and analysis without making file changes. Useful for code review and understanding code without modifications

### Switching Agent

Press `<M-m>` (Alt+M) in the input window to switch between agents during a session.

### Custom Agents

You can create custom agents through your opencode config file. Each agent can have its own:

- Agentl configuration
- Custom prompt
- Enabled/disabled tools
- And more

See [Opencode Agents Documentation](https://opencode.ai/docs/agents/) for full configuration options.

## 📸 Contextual Actions for Snapshots

> [!WARNING] > _Snapshots are an experimental feature_
> in opencode and sometimes the dev team may disable them or change their behavior.
> This repository will be updated to match the latest opencode changes as soon as possible.

Opencode.nvim automatically creates **snapshots** of your workspace at key moments (such as after running prompts or making changes). These snapshots are like lightweight git commits, allowing you to review, compare, and restore your project state at any time.

**Contextual actions** for snapshots are available directly in the output window. When a snapshot is referenced in the conversation, you can trigger actions on it via keymaps displayed by the UI.

### Available Snapshot Actions

- **Diff:** View the differences between the current state and the snapshot.
- **Revert file:** Revert the selected file to the state it was in at the snapshot.
- **Revert all files:** Revert all files in the workspace to the state they were

### How to Use

- When a message in the output references a snapshot (look for 📸 **Created Snapshot** or similar), move your cursor to that line and a little menu will be displayed above.

### Example

When you see a snapshot in the output:

<img src="https://imgur.com/a/wu5PmLM" alt="Opencode.nvim contextual actions" width="90%" />

> **Tip:** Reverting a snapshot will restore all files to the state they were in at that snapshot, so use it with caution!

## 🕛 Contextual Restore points

Opencode.nvim automatically creates restore points before a revet operation. This allows you to undo a revert if needed.

You will see restore points under the Snapshot line like so:
<img src="https://imgur.com/DKCOdt0" alt="Opencode.nvim restore points" width="90%" />

### Available Restore Actions

- **Restore file:** Restore the selected file to the state it was in before the last revert operation.
- **Restore all :** Restore all files in the workspace to the state they were in before the revert action

## Highlight Groups

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
- `OpencodeAgentPlan`: Agent indicator in winbar for Plan mode (default: #61AFEF background)
- `OpencodeAgentBuild`: Agent indicator in winbar for Build mode (default: #616161 background)
- `OpencodeAgentCustom`: Agent indicator in winbar for custom modes (default: #3b4261 background)
- `OpencodeContestualAction`: Highlight for contextual actions in the output window (default: #3b4261 background)
- `OpencodeInpuutLegend`: Highlight for input window legend (default: #CCCCCC background)
- `OpencodeHint`: Highlight for hinting messages in input window and token info in output window footer (linked to `Comment`)

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
   - Configure your preferred LLM provider and model in the `~/.config/opencode/config.json` or `~/.config/opencode/opencode.json` file
