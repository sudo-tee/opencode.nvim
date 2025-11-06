# 🤖 opencode.nvim

<div align="center">
  <img src="https://raw.githubusercontent.com/sst/opencode/dev/packages/web/src/assets/logo-ornate-dark.svg" alt="Opencode logo" width="30%" />
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
- [Agents](#-agents)
- [User Commands](#user-commands)
- [Contextual Actions for Snapshots](#-contextual-actions-for-snapshots)
- [Setting up opencode](#-setting-up-opencode)

## ⚠️Caution

This plugin is in early development and may have bugs and breaking changes. It is not recommended for production use yet. Please report any issues you encounter on the [GitHub repository](https://github.com/sudo-tee/opencode.nvim/issues).

[Opencode](https://github.com/sst/opencode) is also in early development and may have breaking changes. Ensure you are using a compatible version of the Opencode CLI (v0.6.3+ or more).

If your upgrade breaks the plugin, please open an issue or downgrade to the last working version.

## 📋 Requirements

- Opencode (v0.6.3+ or more) CLI installed and available (see [Setting up opencode](#-setting-up-opencode) below)

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
    },
    -- Optional, for file mentions and commands completion, pick only one
    'saghen/blink.cmp',
    -- 'hrsh7th/nvim-cmp',

    -- Optional, for file mentions picker, pick only one
    'folke/snacks.nvim',
    -- 'nvim-telescope/telescope.nvim',
    -- 'ibhagwan/fzf-lua',
    -- 'nvim_mini/mini.nvim',
  },
}
```

## ⚙️ Configuration

> **Note**: The keymap configuration structure has been updated. Old keymaps (`keymap.global` and `keymap.window`) will be mapped to the new format (`keymap.editor`, `keymap.input_window`, `keymap.output_window`) but you should update your config to the new format. See [Keymap Configuration](#keymap-configuration) below for details.

```lua
-- Default configuration with all available options
require('opencode').setup({
  preferred_picker = nil, -- 'telescope', 'fzf', 'mini.pick', 'snacks', if nil, it will use the best available picker. Note mini.pick does not support multiple selections
  preferred_completion = nil, -- 'blink', 'nvim-cmp','vim_complete' if nil, it will use the best available completion
  default_global_keymaps = true, -- If false, disables all default global keymaps
  default_mode = 'build', -- 'build' or 'plan' or any custom configured. @see [OpenCode Agents](https://opencode.ai/docs/modes/)
  keymap_prefix = '<leader>o', -- Default keymap prefix for global keymaps change to your preferred prefix and it will be applied to all keymaps starting with <leader>o
  keymap = {
    editor = {
      ['<leader>og'] = { 'toggle' }, -- Open opencode. Close if opened
      ['<leader>oi'] = { 'open_input' }, -- Opens and focuses on input window on insert mode
      ['<leader>oI'] = { 'open_input_new_session' }, -- Opens and focuses on input window on insert mode. Creates a new session
      ['<leader>oo'] = { 'open_output' }, -- Opens and focuses on output window
      ['<leader>ot'] = { 'toggle_focus' }, -- Toggle focus between opencode and last window
      ['<leader>oT'] = { 'timeline' }, -- Display timeline picker to navigate/undo/redo/fork messages
      ['<leader>oq'] = { 'close' }, -- Close UI windows
      ['<leader>os'] = { 'select_session' }, -- Select and load a opencode session
      ['<leader>op'] = { 'configure_provider' }, -- Quick provider and model switch from predefined list
      ['<leader>od'] = { 'diff_open' }, -- Opens a diff tab of a modified file since the last opencode prompt
      ['<leader>o]'] = { 'diff_next' }, -- Navigate to next file diff
      ['<leader>o['] = { 'diff_prev' }, -- Navigate to previous file diff
      ['<leader>oc'] = { 'diff_close' }, -- Close diff view tab and return to normal editing
      ['<leader>ora'] = { 'diff_revert_all_last_prompt' }, -- Revert all file changes since the last opencode prompt
      ['<leader>ort'] = { 'diff_revert_this_last_prompt' }, -- Revert current file changes since the last opencode prompt
      ['<leader>orA'] = { 'diff_revert_all' }, -- Revert all file changes since the last opencode session
      ['<leader>orT'] = { 'diff_revert_this' }, -- Revert current file changes since the last opencode session
      ['<leader>orr'] = { 'diff_restore_snapshot_file' }, -- Restore a file to a restore point
      ['<leader>orR'] = { 'diff_restore_snapshot_all' }, -- Restore all files to a restore point
      ['<leader>ox'] = { 'swap_position' }, -- Swap Opencode pane left/right
      ['<leader>opa'] = { 'permission_accept' }, -- Accept permission request once
      ['<leader>opA'] = { 'permission_accept_all' }, -- Accept all (for current tool)
      ['<leader>opd'] = { 'permission_deny' }, -- Deny permission request once
    },
    input_window = {
      ['<cr>'] = { 'submit_input_prompt', mode = { 'n', 'i' } }, -- Submit prompt (normal mode and insert mode)
      ['<esc>'] = { 'close' }, -- Close UI windows
      ['<C-c>'] = { 'cancel' }, -- Cancel opencode request while it is running
      ['~'] = { 'mention_file', mode = 'i' }, -- Pick a file and add to context. See File Mentions section
      ['@'] = { 'mention', mode = 'i' }, -- Insert mention (file/agent)
      ['/'] = { 'slash_commands', mode = 'i' }, -- Pick a command to run in the input window
      ['#'] = { 'context_items', mode = 'i' }, -- Manage context items (current file, selection, diagnostics, mentioned files)
      ['<C-i>'] = { 'focus_input', mode = { 'n', 'i' } }, -- Focus on input window and enter insert mode at the end of the input from the output window
      ['<tab>'] = { 'toggle_pane', mode = { 'n', 'i' } }, -- Toggle between input and output panes
      ['<up>'] = { 'prev_prompt_history', mode = { 'n', 'i' } }, -- Navigate to previous prompt in history
      ['<down>'] = { 'next_prompt_history', mode = { 'n', 'i' } }, -- Navigate to next prompt in history
      ['<M-m>'] = { 'switch_mode' }, -- Switch between modes (build/plan)
    },
    output_window = {
      ['<esc>'] = { 'close' }, -- Close UI windows
      ['<C-c>'] = { 'cancel' }, -- Cancel opencode request while it is running
      [']]'] = { 'next_message' }, -- Navigate to next message in the conversation
      ['[['] = { 'prev_message' }, -- Navigate to previous message in the conversation
      ['<tab>'] = { 'toggle_pane', mode = { 'n', 'i' } }, -- Toggle between input and output panes
      ['i'] = { 'focus_input', 'n' }, -- Focus on input window and enter insert mode at the end of the input from the output window
      ['<leader>oS'] = { 'select_child_session' }, -- Select and load a child session
      ['<leader>oD'] = { 'debug_message' }, -- Open raw message in new buffer for debugging
      ['<leader>oO'] = { 'debug_output' }, -- Open raw output in new buffer for debugging
      ['<leader>ods'] = { 'debug_session' }, -- Open raw session in new buffer for debugging
    },
    permission = {
      accept = 'a', -- Accept permission request once (only available when there is a pending permission request)
      accept_all = 'A', -- Accept all (for current tool) permission request once (only available when there is a pending permission request)
      deny = 'd', -- Deny permission request once (only available when there is a pending permission request)
    },
    session_picker = {
      delete_session = { '<C-d>' }, -- Delete selected session in the session picker
    },
    timeline_picker = {
      undo = { '<C-u>', mode = { 'i', 'n' } }, -- Undo to selected message in timeline picker
      fork = { '<C-f>', mode = { 'i', 'n' } }, -- Fork from selected message in timeline picker
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
      preset = 'nerdfonts', -- 'nerdfonts' | 'text'. Choose UI icon style (default: 'nerdfonts')
      overrides = {}, -- Optional per-key overrides, see section below
    },
    output = {
      tools = {
        show_output = true, -- Show tools output [diffs, cmd output, etc.] (default: true)
      },
      rendering = {
        markdown_debounce_ms = 250, -- Debounce time for markdown rendering on new data (default: 250ms)
        on_data_rendered = nil, -- Called when new data is rendered; set to false to disable default RenderMarkdown/Markview behavior
      },
    },
    input = {
      text = {
        wrap = false, -- Wraps text inside input window
      },
    },
    completion = {
      file_sources = {
        enabled = true,
        preferred_cli_tool = 'server', -- 'fd','fdfind','rg','git','server' if nil, it will use the best available tool, 'server' uses opencode cli to get file list (works cross platform) and supports folders
        ignore_patterns = {
          '^%.git/',
          '^%.svn/',
          '^%.hg/',
          'node_modules/',
          '%.pyc$',
          '%.o$',
          '%.obj$',
          '%.exe$',
          '%.dll$',
          '%.so$',
          '%.dylib$',
          '%.class$',
          '%.jar$',
          '%.war$',
          '%.ear$',
          'target/',
          'build/',
          'dist/',
          'out/',
          'deps/',
          '%.tmp$',
          '%.temp$',
          '%.log$',
          '%.cache$',
        },
        max_files = 10,
        max_display_length = 50, -- Maximum length for file path display in completion, truncates from left with "..."
      },
    },
  },
  context = {
    enabled = true, -- Enable automatic context capturing
    cursor_data = {
      enabled = false, -- Include cursor position and line content in the context
    },
    diagnostics = {
      info = false, -- Include diagnostics info in the context (default to false
      warn = true, -- Include diagnostics warnings in the context
      error = true, -- Include diagnostics errors in the context
    },
    current_file = {
      enabled = true, -- Include current file path and content in the context
    },
    selection = {
      enabled = true, -- Include selected text in the context
    },
  },
  debug = {
    enabled = false, -- Enable debug messages in the output window
  },
  prompt_guard = nil, -- Optional function that returns boolean to control when prompts can be sent (see Prompt Guard section)
})
```

### Keymap Configuration

The keymap configuration has been restructured for better organization and clarity:

- **`editor`**: Global keymaps that are available throughout Neovim
- **`input_window`**: Keymaps specific to the input window
- **`output_window`**: Keymaps specific to the output window
- **`permission`**: Special keymaps for responding to permission requests (available in input/output windows when there's a pending permission)

**Backward Compatibility**: The plugin automatically maps configurations that use `keymap.global` and `keymap.window` to the new structure. A deprecation warning will be shown during migration. Update your configuration to use the new structure to remove the warning.

Each keymap entry is a table consising of:

- The string name of an api function = `{ 'toggle' }`
- Or a custom function: `{ function() ... end }`
- An optional mode: `{ 'toggle', mode = { 'n', 'i' } }`
- An optional desc: `{'toggle', desc = 'Toggle Opencode' }`

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

The plugin provides the following actions that can be triggered via keymaps, commands, slash commands (typed in the input window), or the Lua API:

> **Note:** Commands have been restructured into a single `:Opencode` command with subcommands. Legacy `Opencode*` commands (e.g., `:OpencodeOpenInput`) are still available by default but will be removed in a future version. Update your scripts and workflows to use the new nested syntax.

| Action                                                    | Default keymap                        | Command                                     | API Function                                                           |
| --------------------------------------------------------- | ------------------------------------- | ------------------------------------------- | ---------------------------------------------------------------------- |
| Open opencode. Close if opened                            | `<leader>og`                          | `:Opencode`                                 | `require('opencode.api').toggle()`                                     |
| Open input window (current session)                       | `<leader>oi`                          | `:Opencode open input`                      | `require('opencode.api').open_input()`                                 |
| Open input window (new session)                           | `<leader>oI`                          | `:Opencode open input_new_session`          | `require('opencode.api').open_input_new_session()`                     |
| Open output window                                        | `<leader>oo`                          | `:Opencode open output`                     | `require('opencode.api').open_output()`                                |
| Create and switch to a named session                      | -                                     | `:Opencode session new <name>`              | `:Opencode session new <name>` (user command)                          |
| Toggle focus opencode / last window                       | `<leader>ot`                          | `:Opencode toggle focus`                    | `require('opencode.api').toggle_focus()`                               |
| Close UI windows                                          | `<leader>oq`                          | `:Opencode close`                           | `require('opencode.api').close()`                                      |
| Select and load session                                   | `<leader>os`                          | `:Opencode session select`                  | `require('opencode.api').select_session()`                             |
| **Select and load child session**                         | `<leader>oS`                          | `:Opencode session select_child`            | `require('opencode.api').select_child_session()`                       |
| Open timeline picker (navigate/undo/redo/fork to message) | -                                     | `:Opencode timeline`                        | `require('opencode.api').timeline()`                                   |
| Configure provider and model                              | `<leader>op`                          | `:Opencode configure provider`              | `require('opencode.api').configure_provider()`                         |
| Open diff view of changes                                 | `<leader>od`                          | `:Opencode diff open`                       | `require('opencode.api').diff_open()`                                  |
| Navigate to next file diff                                | `<leader>o]`                          | `:Opencode diff next`                       | `require('opencode.api').diff_next()`                                  |
| Navigate to previous file diff                            | `<leader>o[`                          | `:Opencode diff prev`                       | `require('opencode.api').diff_prev()`                                  |
| Close diff view tab                                       | `<leader>oc`                          | `:Opencode diff close`                      | `require('opencode.api').diff_close()`                                 |
| Revert all file changes since last prompt                 | `<leader>ora`                         | `:Opencode revert all prompt`               | `require('opencode.api').diff_revert_all_last_prompt()`                |
| Revert current file changes last prompt                   | `<leader>ort`                         | `:Opencode revert this prompt`              | `require('opencode.api').diff_revert_this_last_prompt()`               |
| Revert all file changes since last session                | `<leader>orA`                         | `:Opencode revert all session`              | `require('opencode.api').diff_revert_all_session()`                    |
| Revert current file changes last session                  | `<leader>orT`                         | `:Opencode revert this session`             | `require('opencode.api').diff_revert_this_session()`                   |
| Revert all files to a specific snapshot                   | -                                     | `:Opencode revert all_to_snapshot`          | `require('opencode.api').diff_revert_all(snapshot_id)`                 |
| Revert current file to a specific snapshot                | -                                     | `:Opencode revert this_to_snapshot`         | `require('opencode.api').diff_revert_this(snapshot_id)`                |
| Restore a file to a restore point                         | -                                     | `:Opencode restore snapshot_file`           | `require('opencode.api').diff_restore_snapshot_file(restore_point_id)` |
| Restore all files to a restore point                      | -                                     | `:Opencode restore snapshot_all`            | `require('opencode.api').diff_restore_snapshot_all(restore_point_id)`  |
| Initialize/update AGENTS.md file                          | -                                     | `:Opencode session agents_init`             | `require('opencode.api').initialize()`                                 |
| Run prompt (continue session) [Run opts](#run-opts)       | -                                     | `:Opencode run <prompt> <opts>`             | `require('opencode.api').run("prompt", opts)`                          |
| Run prompt (new session) [Run opts](#run-opts)            | -                                     | `:Opencode run new_session <prompt> <opts>` | `require('opencode.api').run_new_session("prompt", opts)`              |
| Cancel opencode while it is running                       | `<C-c>`                               | `:Opencode cancel`                          | `require('opencode.api').cancel()`                                     |
| Set mode to Build                                         | -                                     | `:Opencode agent build`                     | `require('opencode.api').agent_build()`                                |
| Set mode to Plan                                          | -                                     | `:Opencode agent plan`                      | `require('opencode.api').agent_plan()`                                 |
| Select and switch mode/agent                              | -                                     | `:Opencode agent select`                    | `require('opencode.api').select_agent()`                               |
| Display list of availale mcp servers                      | -                                     | `:Opencode mcp`                             | `require('opencode.api').mcp()`                                        |
| Run user commands                                         | -                                     | `:Opencode run user_command`                | `require('opencode.api').run_user_command()`                           |
| Share current session and get a link                      | -                                     | `:Opencode session share` / `/share`        | `require('opencode.api').share()`                                      |
| Unshare current session (disable link)                    | -                                     | `:Opencode session unshare` / `/unshare`    | `require('opencode.api').unshare()`                                    |
| Compact current session (summarize)                       | -                                     | `:Opencode session compact` / `/compact`    | `require('opencode.api').compact_session()`                            |
| Undo last opencode action                                 | -                                     | `:Opencode undo` / `/undo`                  | `require('opencode.api').undo()`                                       |
| Redo last opencode action                                 | -                                     | `:Opencode redo` / `/redo`                  | `require('opencode.api').redo()`                                       |
| Respond to permission requests (accept once)              | `a` (window) / `<leader>opa` (global) | `:Opencode permission accept`               | `require('opencode.api').permission_accept()`                          |
| Respond to permission requests (accept all)               | `A` (window) / `<leader>opA` (global) | `:Opencode permission accept_all`           | `require('opencode.api').permission_accept_all()`                      |
| Respond to permission requests (deny)                     | `d` (window) / `<leader>opd` (global) | `:Opencode permission deny`                 | `require('opencode.api').permission_deny()`                            |
| Insert mention (file/ agent)                              | `@`                                   | -                                           | -                                                                      |
| [Pick a file and add to context](#file-mentions)          | `~`                                   | -                                           | -                                                                      |
| Navigate to next message                                  | `]]`                                  | -                                           | -                                                                      |
| Navigate to previous message                              | `[[`                                  | -                                           | -                                                                      |
| Navigate to previous prompt in history                    | `<up>`                                | -                                           | `require('opencode.api').prev_history()`                               |
| Navigate to next prompt in history                        | `<down>`                              | -                                           | `require('opencode.api').next_history()`                               |
| Toggle input/output panes                                 | `<tab>`                               | -                                           | -                                                                      |
| Swap Opencode pane left/right                             | `<leader>ox`                          | `:Opencode swap position`                   | `require('opencode.api').swap_position()`                              |

---

### Run opts

You can pass additional options when running a prompt via command or API:

- `agent=<agent_name>`: Specify the agent to use for this prompt (overrides current agent)
- `model=<provider/model_name>`: Specify the model to use for this prompt (overrides current model) e.g. `model=github-copilot/gpt-4.1`
- `context.<context_type>.enabled=<true|false>`: Enable/disable specific context types for this prompt only. Available context types:
  - `current_file`
  - `selection`
  - `diagnostics.info`
  - `diagnostics.warn`
  - `diagnostics.error`
  - `cursor_data`

#### Example

Run a prompt in a new session using the Plan agent and disabling current file context:

```vim
:Opencode run new_session "Please help me plan a new feature" agent=plan context.current_file.enabled=false
:Opencode run "Fix the bug in the current file" model=github-copilot/claude-sonned-4
```

##👮 Permissions

Opencode can issue permission requests for potentially destructive operations (file edits, reverting files, running shell commands, or enabling persistent tool access). Permission requests appear inline in the output and must be responded to before the agent performs the action. Visit [Opencode Permissions Documentation](https://opencode.ai/docs/permissions/) for more details.

<div align="center">
  <img src="https://i.imgur.com/LkZDta5.png" alt="Opencode permission request" width="90%" />
  <img src="https://i.imgur.com/4mJH1Xg.png" alt="Opencode permission request input window" width="90%" />
</div>

### Responding to Permission Requests

- **Respond via keys:** In the input window press `a` to accept once, `A` to accept and remember (accept all), or `d` to deny. These window keys are configurable in `ui.keymap.window.permission_*`.
- **Global keymaps:** There are also global keymaps to respond outside the input window: `<leader>opa` (accept once), `<leader>opA` (accept all), `<leader>opd` (deny). These are configurable in `keymap.global.permission_*`.
- **API:** Programmatic responses are available: `require('opencode.api').permission_accept()`, `require('opencode.api').permission_accept_all()`, `require('opencode.api').permission_deny()` which map to responses `"once"`, `"always"`, and `"reject"` respectively.
- **Behavior:** `accept once` allows the single requested action, `accept all` grants persistent permission for similar requests in the current session, and `deny` rejects the request.

---

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

### Context bar

You can quiclkly see the current context items in the context bar at the top of the input window:

<div align="center">
  <img src="https://i.imgur.com/vGgu6br.png" alt="Opencode.nvim context bar" width="90%" />
</div>

### Context Items Completion

You can quickly reference available context items by typing `#` in the input window. This will show a completion menu with all available context items:

- **Current File** - The currently focused file in the editor
- **Selection** - Currently selected text in visual mode
- **Diagnostics** - LSP diagnostics from the current file
- **Cursor Data** - Current cursor position and line content
- **[filename]** - Files that have been mentioned in the conversation
- **Agents** - Available agents to switch to
- **Selections** - Previously made selections in visual mode

Context items that are not currently available will be shown as disabled in the completion menu.

You should also see the list of files agents and selections in the menu, selecting them in the menu will remove them from the context.

<div align="center">
  <img src="https://i.imgur.com/UqQKW33.png" alt="Opencode.nvim context items completion" width="90%" />
</div>

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

## User Commands and Slash Commands

You can run predefined user commands and built-in slash commands from the input window by typing `/`. This opens a command picker where you can select a command to execute. The output of the command will be included in your prompt context.

**Built-in slash commands** include:

- `/share` — Share the current session and get a link
- `/unshare` — Unshare the current session
- `/compact` — Compact (summarize) the current session
- `/undo` — Undo the last opencode action
- `/redo` — Redo the last undone action
- `/agents_init` — Initialize/update AGENTS.md
- `/help` — Show help
- `/mcp` — Show MCP servers
- `/models` — Switch provider/model
- `/sessions` — Switch session
- `/child-sessions` — Switch to a child session
- `/agent` — Switch agent/mode
- ...and more

**User commands** are custom scripts you define. They are loaded from:

- `.opencode/command/` (project-specific)
- `command/` (global, in config directory)

You can also run user commands by name with `:Opencode command <name>`.

<img src="https://i.imgur.com/YQhhoPS.png" alt="Opencode.nvim contextual actions" width="90%" />

See [User Commands Documentation](https://opencode.ai/docs/commands/) for more details.

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

<img src="https://i.imgur.com/eKOjhTN.png" alt="Opencode.nvim contextual actions" width="90%" />

> **Tip:** Reverting a snapshot will restore all files to the state they were in at that snapshot, so use it with caution!

## 🕛 Contextual Restore points

Opencode.nvim automatically creates restore points before a revet operation. This allows you to undo a revert if needed.

You will see restore points under the Snapshot line like so:
<img src="https://i.imgur.com/DKCOdt0.png" alt="Opencode.nvim restore points" width="90%" />

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
- `OpencodeInputLegend`: Highlight for input window legend (default: #CCCCCC background)
- `OpencodeHint`: Highlight for hinting messages in input window and token info in output window footer (linked to `Comment`)

## 🛡️ Prompt Guard

The `prompt_guard` configuration option allows you to control when prompts can be sent to Opencode. This is useful for preventing accidental or unauthorized AI interactions in certain contexts.

### Configuration

Set `prompt_guard` to a function that returns a boolean:

```lua
require('opencode').setup({
  prompt_guard = function()
    -- Your custom logic here
    -- Return true to allow, false to deny
    return true
  end,
})
```

### Behavior

- **Before sending prompts**: The guard is checked before any prompt is sent to the AI. If denied, an ERROR notification is shown and the prompt is not sent.
- **Before opening UI**: The guard is checked when opening the Opencode buffer for the first time. If denied, a WARN notification is shown and the UI is not opened.
- **No parameters**: The guard function receives no parameters. Access vim state directly (e.g., `vim.fn.getcwd()`, `vim.bo.filetype`).
- **Error handling**: If the guard function throws an error or returns a non-boolean value, the prompt is denied with an appropriate error message.

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
