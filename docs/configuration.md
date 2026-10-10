# Configuration

[Documentation](README.md) / Configuration

Start with `setup({})` and set only what you want to change. Every option and
keymap is in the [full default configuration](#full-default-configuration);
types are in [`lua/opencode/types.lua`](../lua/opencode/types.lua).

To see the settings in effect:

```vim
:lua print(vim.inspect(require('opencode.config').values))
```

Server credentials show up in this output, so check it before sharing.

## Common starting points

```lua
require('opencode').setup({
  keymap_prefix = '<leader>a',
  preferred_picker = 'snacks',
  ui = {
    position = 'left',
    window_width = 0.35,
    icons = { preset = 'text' },
  },
})
```

| Option | Default | Purpose |
| --- | --- | --- |
| `preferred_picker` | `nil` | Auto-detect; choices: `telescope`/`telescope.nvim`, `fzf`/`fzf-lua`, `mini.pick`, `snacks`/`snacks.nvim`, `select` |
| `default_global_keymaps` | `true` | Install the default editor-wide mappings |
| `keymap_prefix` | `'<leader>o'` | Rewrites mappings that start with `<leader>o` to use this prefix |
| `default_mode` | `'build'` | Initial agent, including custom agent names |
| `default_system_prompt` | `nil` | Custom system prompt for sessions |
| `opencode_executable` | `'opencode'` | CLI name or path |
| `lock_session_to_directory` | `false` | `true` preserves the active session across `DirChanged`; a function decides per change |
| `child_readonly` | `true` | Block messaging and hide input in child sessions |

Server settings are covered in [Servers](servers.md). Quick chat options are
covered in [Usage](usage.md#quick-chat-experimental).

## Directory changes

By default, changing Neovim's directory loads the target directory's last
session. Set `lock_session_to_directory = true` to keep the active session
instead, including a panel tab's bound directory.

The option also accepts a function receiving `{ from, to, session }`. Return
`true` to keep the active session or `false` to follow the new directory.
`from` is the bound directory, or the directory the session was loaded from;
`to` is the new directory. Callback errors are reported and fall back to
following cwd. Manual lock toggles override the policy per panel tab.

For example, this policy keeps a conversation when moving between worktrees of
the same repository. Put it in your existing `setup()` options:

```lua
require('opencode').setup({
  lock_session_to_directory = function(change)
    local function common_dir(dir)
      local result = vim.system({
        'git', '-C', dir, 'rev-parse', '--path-format=absolute', '--git-common-dir',
      }, { text = true }):wait()
      return result.code == 0 and vim.trim(result.stdout) or nil
    end
    local repo = common_dir(change.from)
    return repo ~= nil and repo == common_dir(change.to)
  end,
})
```

This keeps the conversation; it does not move the session to the new worktree.
For separate conversations, see [Worktree sessions](recipes/worktree.md).

## Full default configuration

Optional callbacks and values are shown as `nil`.

<details>
<summary>Show all default options</summary>

```lua
require('opencode').setup({
  preferred_picker = nil,
  default_global_keymaps = true,
  default_mode = 'build',
  default_system_prompt = nil,
  keymap_prefix = '<leader>o',
  opencode_executable = 'opencode',
  lock_session_to_directory = false,
  server = {
    url = nil,
    port = nil,
    timeout = 5,
    retry_delay = 2000,
    health_check_ttl_ms = 5000,
    spawn_command = nil,
    kill_command = nil,
    auto_kill = true,
    path_map = nil,
    reverse_path_map = nil,
    username = nil,
    password = nil,
    password_file = nil,
  },
  -- stylua: ignore
  keymap = {
    session_diff = {
      list = {
        ['<CR>'] = { 'activate', desc = 'Open file or toggle folder' },
        ['gf'] = { 'open_file', desc = 'Open working-tree file in a new tab' },
        ['<Tab>'] = { 'next_file', desc = 'Next file' },
        ['<S-Tab>'] = { 'prev_file', desc = 'Previous file' },
        ['r'] = { 'toggle_range', desc = 'Choose message range', nowait = true },
        ['p'] = { 'toggle_view', desc = 'Toggle diff layout' },
        ['q'] = { 'close', desc = 'Close diff', nowait = true },
        ['g?'] = { 'toggle_help', desc = 'Toggle keymap help' },
      },
      messages = {
        ['<CR>'] = { 'activate', desc = 'Review selected range' },
        ['r'] = { 'toggle_range', desc = 'Return to files' },
        ['f'] = { 'mark_from', desc = 'Mark range start' },
        ['t'] = { 'mark_to', desc = 'Mark range end' },
        ['K'] = { 'show_message_preview', desc = 'Preview message' },
        ['<Esc>'] = { 'toggle_range', desc = 'Return to files' },
        ['q'] = { 'toggle_range', desc = 'Return to files', nowait = true },
        ['g?'] = { 'toggle_help', desc = 'Toggle keymap help' },
      },
      preview = {
        ['gf'] = { 'open_file', desc = 'Open working-tree file in a new tab' },
        ['<Tab>'] = { 'next_file', desc = 'Next file' },
        ['<S-Tab>'] = { 'prev_file', desc = 'Previous file' },
        ['q'] = { 'close', desc = 'Close diff', nowait = true },
        ['p'] = { 'toggle_view', desc = 'Toggle diff layout' },
        ['g?'] = { 'toggle_help', desc = 'Toggle keymap help' },
        ['c'] = { 'add_comment', mode = { 'n', 'x' },  desc = 'Add or edit review comment', nowait = true  },
        ['dc'] = { 'delete_comment', desc = 'Delete review comment' },
        [']r'] = { 'next_comment', desc = 'Next review comment' },
        ['[r'] = { 'prev_comment', desc = 'Previous review comment' },
      },
      comment = {
        ['<CR>'] = { 'submit_comment', mode = 'n', desc = 'Save review comment' },
        ['<C-s>'] = { 'submit_comment', mode = { 'n', 'i' }, desc = 'Save review comment' },
        ['q'] = { 'cancel_comment', desc = 'Cancel review comment', nowait = true },
        ['<Esc>'] = { 'cancel_comment', desc = 'Cancel review comment' },
      },
      message_preview = {
        ['q'] = { 'hide_message_preview', desc = 'Close message preview', nowait = true },
        ['<Esc>'] = { 'hide_message_preview', desc = 'Close message preview' },
        ['g?'] = { 'toggle_help', desc = 'Toggle keymap help' },
      },
      help = {
        ['g?'] = { 'toggle_help' },
        ['q'] = { 'toggle_help', nowait = true },
        ['<Esc>'] = { 'toggle_help' },
      },
    },
    editor = {
      ['<leader>og'] =  { 'toggle',                                            desc = 'Toggle Opencode window' },
      ['<leader>oi'] =  { 'open_input',                                        desc = 'Open input window' },
      ['<leader>oI'] =  { 'open_input_new_session',                            desc = 'Open input (new session)' },
      ['<leader>oN'] =  { 'open_session_tab',                                  desc = 'Open new Opencode session tab' },
      ['<leader>o<'] =  { 'prev_session_tab',                                  desc = 'Previous Opencode session tab' },
      ['<leader>o>'] =  { 'next_session_tab',                                  desc = 'Next Opencode session tab' },
      ['<leader>o?'] =  { 'select_session_tab',                                desc = 'Select Opencode session tab' },
      ['<leader>o1'] =  { 'select_session_tab', { 1 },                          desc = 'Select Opencode session tab 1' },
      ['<leader>o2'] =  { 'select_session_tab', { 2 },                          desc = 'Select Opencode session tab 2' },
      ['<leader>o3'] =  { 'select_session_tab', { 3 },                          desc = 'Select Opencode session tab 3' },
      ['<leader>o4'] =  { 'select_session_tab', { 4 },                          desc = 'Select Opencode session tab 4' },
      ['<leader>o5'] =  { 'select_session_tab', { 5 },                          desc = 'Select Opencode session tab 5' },
      ['<leader>o6'] =  { 'select_session_tab', { 6 },                          desc = 'Select Opencode session tab 6' },
      ['<leader>o7'] =  { 'select_session_tab', { 7 },                          desc = 'Select Opencode session tab 7' },
      ['<leader>o8'] =  { 'select_session_tab', { 8 },                          desc = 'Select Opencode session tab 8' },
      ['<leader>o9'] =  { 'select_session_tab', { 9 },                          desc = 'Select Opencode session tab 9' },
      ['<leader>oh'] =  { 'select_history',                                    desc = 'Select from history' },
      ['<leader>oo'] =  { 'open_output',                                       desc = 'Open output window' },
      ['<leader>ot'] =  { 'toggle_focus',                                      desc = 'Toggle focus' },
      ['<leader>oT'] =  { 'timeline',                                          desc = 'Session timeline' },
      ['<leader>oq'] =  { 'close',                                             desc = 'Close Opencode window' },
      ['<leader>oQ'] =  { 'close_session_tab',                                 desc = 'Close current Opencode session tab' },
      ['<leader>os'] =  { 'select_session',                                    desc = 'Select session' },
      ['<leader>oS'] =  { 'navigate_session_tree', { 'child', 'picker' },     desc = 'Select child session' },
      ['<leader>oP'] =  { 'navigate_session_tree', { 'parent' },              desc = 'Go to parent session' },
      ['<leader>oB'] =  { 'navigate_session_tree', { 'sibling', 'picker' },   desc = 'Select sibling session' },
      ['<leader>oR'] =  { 'rename_session',                                    desc = 'Rename session' },
      ['<leader>op'] =  { 'configure_provider',                                desc = 'Configure provider' },
      ['<leader>oV'] =  { 'configure_variant',                                 desc = 'Configure model variant' },
      ['<leader>oy'] =  { 'add_visual_selection',         mode = { 'v' },      desc = 'Add visual selection to context' },
      ['<leader>oY'] =  { 'add_visual_selection_inline',  mode = { 'v' },      desc = 'Insert visual selection inline into input' },
      ['<leader>oz'] =  { 'toggle_zoom',                                       desc = 'Toggle zoom' },
      ['<leader>ov'] =  { 'paste_image',                                       desc = 'Paste image from clipboard' },
      ['<leader>od'] =  { 'diff_open',                                         desc = 'Open diff view' },
      ['<leader>o]'] =  { 'diff_next',                                         desc = 'Next diff' },
      ['<leader>o['] =  { 'diff_prev',                                         desc = 'Previous diff' },
      ['<leader>oc'] =  { 'diff_close',                                        desc = 'Close diff view' },
      ['<leader>ora'] = { 'diff_revert_all_last_prompt',                       desc = 'Revert all (last prompt)' },
      ['<leader>ort'] = { 'diff_revert_this_last_prompt',                      desc = 'Revert this (last prompt)' },
      ['<leader>orA'] = { 'diff_revert_all',                                   desc = 'Revert all changes' },
      ['<leader>orT'] = { 'diff_revert_this',                                  desc = 'Revert this change' },
      ['<leader>orr'] = { 'diff_restore_snapshot_file',                        desc = 'Restore file snapshot' },
      ['<leader>orR'] = { 'diff_restore_snapshot_all',                         desc = 'Restore all snapshots' },
      ['<leader>ox'] =  { 'swap_position',                                     desc = 'Swap window position' },
      ['<leader>otr'] = { 'toggle_reasoning_output',                           desc = 'Toggle reasoning output' },
      ['<leader>ott'] = { 'toggle_tool_output',                                desc = 'Toggle tool output' },
      ['<leader>otm'] = { 'toggle_max_messages',                               desc = 'Toggle max messages' },
      ['<leader>o/'] =  { 'quick_chat',                   mode = { 'n', 'x' }, desc = 'Quick chat with current context' },
      ['<leader>oDu'] = { 'copy_server_url',                                   desc = 'Copy server url' },

    },
    output_window = {
      ['gg'] =         { 'first_message',                                     desc = 'Load history and go to the first message' },
      ['<esc>'] =       { 'close',                                             desc = 'Close Opencode windows' },
      ['<C-c>'] =       { 'cancel',                                            desc = 'Cancel running request' },
      [']]']   =        { 'next_message',                                      desc = 'Go to next message' },
      ['[[']   =        { 'prev_message',                                      desc = 'Go to previous message' },
      [']u']   =        { 'next_user_message',                                 desc = 'Go to next user message' },
      ['[u']   =        { 'prev_user_message',                                 desc = 'Go to previous user message' },
      ['<tab>'] =       { 'toggle_pane',                  mode = { 'n' },      desc = 'Toggle input/output panes' },
      ['i']     =       { 'focus_input',                                       desc = 'Focus input window' },
      ['gr']    =       { 'references',                                        desc = 'Browse code references' },
      ['gf']    =       { 'jump_to_file',                                       desc = 'Jump to file at cursor' },
      ['<CR>']  =       { 'jump_to_target_at_cursor',                          desc = 'Jump to target at cursor' },
      ['gd']    =       { 'jump_to_target_at_cursor',                          desc = 'Jump to target at cursor' },
      ['<M-i>'] =       { 'toggle_input',                 mode = { 'n' },      desc = 'Toggle input window' },
      ['<M-r>'] =       { 'cycle_variant',                mode = { 'n' },      desc = 'Cycle model variants' },
      ['<leader>oS'] =  { 'navigate_session_tree', { 'child', 'picker' },     desc = 'Select child session' },
      ['<leader>oP'] =  { 'navigate_session_tree', { 'parent' },              desc = 'Go to parent session' },
      ['<leader>oB'] =  { 'navigate_session_tree', { 'sibling', 'picker' },   desc = 'Select sibling session' },
      ['<leader>oD'] =  { 'debug_message',                                     desc = 'Open raw message debug view' },
      ['<leader>oO'] =  { 'debug_output',                                      desc = 'Open raw output debug view' },
      ['<leader>oDs'] = { 'debug_session',                                     desc = 'Open raw session debug view' },
    },
    tab_strip_window = {
      ['<LeftMouse>'] =   { 'select_session_tab_target', { 'mouse' },  nowait = true, desc = 'Select tab under mouse' },
      ['<2-LeftMouse>'] = { 'select_session_tab_target', { 'mouse' },  nowait = true, desc = 'Select tab under mouse' },
      ['<CR>'] =          { 'select_session_tab_target', { 'cursor' }, nowait = true, desc = 'Select tab under cursor' },
    },
    input_window = {
      ['<cr>']   =      { 'submit_input_prompt',          mode = { 'n' },      desc = 'Submit prompt'                                            },
      ['<S-cr>'] =      { 'submit_input_prompt',          mode = { 'n', 'i' }, desc = 'Submit prompt'                                            },
      ['<esc>']  =      { 'close',                                             desc = 'Close Opencode windows',       defer_to_completion = true },
      ['<C-c>']  =      { 'cancel',                                            desc = 'Cancel running request' ,      defer_to_completion = true },
      ['~']      =      { 'mention_file',                 mode = 'i',          desc = 'Mention file in context'                                  },
      ['@']      =      { 'mention',                      mode = 'i',          desc = 'Open mention picker'                                      },
      ['/']      =      { 'slash_commands',               mode = 'i',          desc = 'Open slash commands picker'                               },
      ['#']      =      { 'context_items',                mode = 'i',          desc = 'Open context items picker'                                },
      ['<M-v>']  =      { 'paste_image',                  mode = 'i',          desc = 'Paste image from clipboard'                               },
      ['<tab>']  =      { 'toggle_pane',                  mode = { 'n' },      desc = 'Toggle input/output panes',    defer_to_completion = true },
      ['<up>']   =      { 'prev_prompt_history',          mode = { 'n', 'i' }, desc = 'Previous prompt history item', defer_to_completion = true },
      ['<down>'] =      { 'next_prompt_history',          mode = { 'n', 'i' }, desc = 'Next prompt history item' ,    defer_to_completion = true },
      ['<M-m>']  =      { 'switch_mode',                  mode = { 'n', 'i' }, desc = 'Switch agent mode'                                        },
      ['<M-r>']  =      { 'cycle_variant',                mode = { 'n', 'i' }, desc = 'Cycle model variants'                                     },
      ['<M-i>']  =      { 'toggle_input',                 mode = { 'n', 'i' }, desc = 'Toggle input window'                                      },
      ['gr']     =      { 'references',                                        desc = 'Browse code references'                                   },
      ['<leader>oS'] =  { 'navigate_session_tree', { 'child', 'picker' },     desc = 'Select child session' },
      ['<leader>oP'] =  { 'navigate_session_tree', { 'parent' },              desc = 'Go to parent session' },
      ['<leader>oB'] =  { 'navigate_session_tree', { 'sibling', 'picker' },   desc = 'Select sibling session' },
      ['<leader>oD'] =  { 'debug_message',                                     desc = 'Open raw message debug view'                              },
      ['<leader>oO'] =  { 'debug_output',                                      desc = 'Open raw output debug view'                               },
      ['<leader>oDs'] = { 'debug_session',                                     desc = 'Open raw session debug view'                              },
    },
    session_picker = {
      rename_session = { '<C-r>',                                              desc = 'Rename selected session' },
      delete_session = { '<C-d>',                                              desc = 'Delete selected sessions' },
      new_session =    { '<C-s>',                                              desc = 'Create a new session' },
      open_in_tab =    { '<C-t>',                                              desc = 'Open selected session in a new panel tab' },
      fork_session =  { '<C-f>',                                              desc = 'Fork selected session' },
      toggle_scope =  { '<C-g>',                                              desc = 'Toggle between project/global scope' },
    },
    session_tab_picker = {
      new_tab =   { '<C-s>', desc = 'Create a new panel tab' },
      close_tab = { '<C-d>', desc = 'Close selected panel tab' },
    },
    timeline_picker = {
      undo = { '<C-u>',                                   mode = { 'i', 'n' }, desc = 'Undo to selected message' },
      fork = { '<C-f>',                                   mode = { 'i', 'n' }, desc = 'Fork from selected message' },
    },
    history_picker = {
      delete_entry = { '<C-d>',                           mode = { 'i', 'n' }, desc = 'Delete selected history entries' },
      clear_all =    { '<C-X>',                           mode = { 'i', 'n' }, desc = 'Clear all history entries' },
    },
    model_picker = {
      toggle_favorite = { '<C-f>',                        mode = { 'i', 'n' }, desc = 'Toggle model favorite' },
    },
    mcp_picker = {
      toggle_connection = { '<C-t>',                      mode = { 'i', 'n' }, desc = 'Toggle MCP server connection' },
    },
    quick_chat = {
      cancel = { '<C-c>',                                 mode = { 'i', 'n' }, desc = 'Cancel active quick chat requests' },
    },
  },
  ui = {
    enable_treesitter_markdown = true,
    position = 'right',
    input_position = 'bottom',
    window_width = 0.40,
    zoom_width = 0.8,
    float = {
      width = 0.95,
      height = 0.9,
      row = nil,
      col = nil,
      border = 'rounded',
      gap = 1,
      zindex = 40,
      opts = {
        winblend = 0,
      },
    },
    picker_width = 100,
    display_model = true,
    display_context_size = true,
    display_cost = true,
    hide_single_tab = true,
    notify_on_background_prompt = true,
    window_highlight = 'Normal:OpencodeBackground,FloatBorder:OpencodeBorder',
    persist_state = true,
    icons = {
      preset = 'nerdfonts',
      overrides = {},
    },
    loading_animation = {
      frames = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' },
    },
    output = {
      filetype = 'opencode_output',
      time_format = nil,
      compact_assistant_headers = false,
      actions = {
        open_in_new_tab = false,
      },
      rendering = {
        markdown_debounce_ms = 250,
        on_data_rendered = nil,
        markdown_on_idle = false,
        -- If set to a number, markdown rendering will be deferred while
        -- `state.user_message_count[session_id]` is greater than this value.
        -- If `nil`, the existing behavior is used (defer while > 0).
        markdown_on_idle_threshold = nil,
        event_throttle_ms = 40,
        event_collapsing = true,
      },
      tools = {
        show_output = true,
        show_reasoning_output = true,
        use_folds = true,
        fold_exclude = { { server = 'sequential-thinking', tool = 'sequentialthinking' } },
        -- Reduced default threshold to make small tool outputs foldable by default.
        -- Users can override this in their config if they prefer the previous value.
        folding_threshold = 25,
      },

      max_messages = nil,
      always_scroll_to_bottom = false,
    },
    questions = {
      use_vim_ui_select = false, -- If true, render questions with vim.ui.select instead of in the output buffer
      inline_other_input = true, -- If true, show an inline floating input for "Other" instead of cmdline prompt
    },
    input = {
      min_height = 0.10,
      max_height = 0.25,
      text = {
        wrap = false,
      },
      -- Auto-hide input window when prompt is submitted or focus switches to output window
      auto_hide = false,
      -- Window-local options applied to the input window.
      -- Any valid Neovim window option can be added here.
      -- Users can override these and add any extra option, e.g.:
      --   win_options = { signcolumn = 'no', cursorline = true, conceallevel = 2 }
      win_options = {
        signcolumn = 'yes',
        cursorline = false,
        number = false,
        relativenumber = false,
      },
    },
    picker = {
      snacks_layout = nil,
    },
    completion = {
      file_sources = {
        enabled = true,
        preferred_cli_tool = 'server',
        ignore_patterns = {
          '^%.git/',
          '^%.svn/',
          '^%.hg/',
          '^%.jj/',
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
        max_display_length = 50,
      },
    },
  },
  context = {
    enabled = true,
    cursor_data = {
      enabled = false,
      context_lines = 5, -- Number of lines before and after cursor to include in context
    },
    diagnostics = {
      enabled = true,
      info = false,
      warning = true,
      error = true,
      only_closest = true, -- Only diagnostics for cursor/selection; disable to include the whole buffer
    },
    current_file = {
      enabled = true,
      show_full_path = true,
    },
    files = {
      enabled = true,
      show_full_path = true,
    },
    selection = {
      enabled = true,
    },
    review_comments = {
      enabled = true,
    },
    agents = {
      enabled = true,
    },
    buffer = {
      enabled = false, -- Disable entire buffer context by default, only used in quick chat
    },
    git_diff = {
      enabled = false,
    },
  },
  logging = {
    enabled = false,
    level = 'info', -- debug, info, warn, error
    outfile = nil,
  },
  debug = {
    enabled = false,
    capture_streamed_events = false,
    show_ids = true,
    highlight_changed_lines = false,
    highlight_changed_lines_timeout_ms = 120,
    quick_chat = {
      keep_session = false,
      set_active_session = false,
    },
  },
  prompt_guard = nil,
  child_readonly = true,
  snapshot_path = nil,
  hooks = {
    on_file_edited = nil,
    on_session_loaded = nil,
    on_done_thinking = nil,
    on_permission_requested = nil,
    on_question_asked = nil,
    on_topbar_render = nil,
    on_footer_render = nil,
  },
  quick_chat = {
    default_model = nil,
    default_agent = nil,
    instructions = nil, -- Use instructions prompt by default
  },
})
```

</details>

## Keymaps

Mappings are grouped by where they apply:

- `editor`: global mappings.
- `input_window`, `output_window`, `tab_strip_window`: panel-local mappings.
- `session_diff`: review-local mappings, split into `list`, `messages`,
  `preview`, `comment`, `message_preview`, and `help`.
- Picker tables such as `session_picker`, `timeline_picker`, `history_picker`,
  `model_picker`, and `mcp_picker`: action names mapped to keys.

A panel mapping entry accepts an action name or callback, an optional argument
table, and options including `mode`, `desc`, and `defer_to_completion`.
Unspecified mappings keep their defaults; `false` disables a key.

```lua
require('opencode').setup({
  keymap = {
    input_window = {
      ['<S-cr>'] = false,
      ['<C-s>'] = {
        'submit_input_prompt',
        mode = { 'n', 'i' },
        desc = 'Send prompt',
      },
    },
    editor = {
      ['<leader>oy'] = {
        'add_visual_selection', { open_input = false }, mode = { 'v' },
      },
    },
  },
})
```

`defer_to_completion = true` lets an open completion menu handle the key before
the plugin action. It is useful for keys such as `<Tab>`, `<Up>`, and `<Down>`.

To own all global mappings, disable defaults and define only your keys:

```lua
require('opencode').setup({
  default_global_keymaps = false,
  keymap = {
    editor = {
      ['<leader>ai'] = { 'open_input', desc = 'Ask OpenCode' },
      ['<leader>ad'] = { 'diff_open', desc = 'Review OpenCode changes' },
    },
  },
})
```

This does not disable panel-local mappings. The full current bindings are in
[`config.lua`](../lua/opencode/config.lua); the [usage guide](usage.md) lists
the everyday ones. Session diff remapping has its own [example](review.md#customize-review-keys).

## Window layout

| Option | Default | Meaning |
| --- | --- | --- |
| `ui.position` | `'right'` | `right`, `left`, `current`, or `float` |
| `ui.input_position` | `'bottom'` | `bottom` or `top` |
| `ui.window_width` | `0.40` | Split width as a fraction of editor width |
| `ui.zoom_width` | `0.8` | Zoomed split width |
| `ui.persist_state` | `true` | Preserve UI buffers when closing/hiding |
| `ui.input.min_height` / `max_height` | `0.10` / `0.25` | Input height bounds as window-height fractions |
| `ui.input.text.wrap` | `false` | Wrap prompt text |
| `ui.input.auto_hide` | `false` | Hide input after submission or focus moves to output |
| `ui.hide_single_tab` | `true` | Hide the strip with one panel tab |
| `ui.notify_on_background_prompt` | `true` | Notify about background questions/permissions |

Floating windows use `ui.float`, with width `0.95`, height `0.9`, rounded border,
gap `1`, and z-index `40` by default. Optional `row` and `col` control position.

Apply window-local input options with `ui.input.win_options`:

```lua
require('opencode').setup({
  ui = {
    input = {
      text = { wrap = true },
      win_options = { signcolumn = 'no', cursorline = true },
    },
  },
})
```

For a more involved layout toggle, see the
[three-state recipe](recipes/three-state-layout/README.md).

## Output and rendering

- `ui.display_model`, `display_context_size`, and `display_cost` are on by default.
- `ui.output.compact_assistant_headers` accepts `false`/`'full'`,
  `true`/`'minimal'`, or `'hidden'`. Minimal headers collapse repeated agent
  information.
- `ui.output.max_messages = nil` means no initial limit. With a limit, scrolling
  up, `[[`, or `gg` loads older messages. `<leader>otm` toggles the limit.
- `ui.output.always_scroll_to_bottom = false` allows reading older output.
- `ui.output.time_format` accepts an `os.date` format or `nil` for the default.
- `ui.output.actions.open_in_new_tab = false` makes inline child/fork actions
  replace the active session. Set it to `true` to open them in a new panel tab.

Tool output and reasoning are shown by default. Foldable output uses a threshold
of 25 lines. Customize with:

```lua
require('opencode').setup({
  ui = {
    output = {
      tools = {
        show_reasoning_output = false,
        folding_threshold = 40,
        fold_exclude = {
          'bash',
          { server = 'sequential-thinking', tool = 'sequentialthinking' },
        },
      },
    },
  },
})
```

`fold_exclude` accepts exact built-in tool names or MCP server/tool pairs.
`<leader>ott` and `<leader>otr` toggle tool and reasoning output at runtime.

Markdown Treesitter support is enabled by `ui.enable_treesitter_markdown`.
Rendering settings live under `ui.output.rendering`: debounce is `250` ms,
stream-event throttle is `40` ms, and event collapsing is on. Set
`on_data_rendered` to a callback `(buf, win)` to customize post-render behavior,
or `false` to disable the default RenderMarkdown/Markview behavior.
For slower setups, `markdown_on_idle = true` defers Markdown rendering while
prompts are active; `markdown_on_idle_threshold` adjusts that threshold.

## Icons

The default preset is `nerdfonts`. For a plain-text UI:

```lua
require('opencode').setup({
  ui = { icons = { preset = 'text' } },
})
```

Override individual keys without replacing the preset:

```lua
require('opencode').setup({
  ui = {
    icons = {
      preset = 'text',
      overrides = { header_user = '> ', header_assistant = 'AI ', search = 'FIND ' },
    },
  },
})
```

All supported keys are listed in [`ui/icons.lua`](../lua/opencode/ui/icons.lua).
Highlight customization is covered in [Hooks and events](extensions.md#highlights).

## Context

Read [Context](context.md) for what gets sent and when. A focused setup might
disable automatic current-file attachment while keeping selections:

```lua
require('opencode').setup({
  context = {
    current_file = { enabled = false },
    selection = { enabled = true },
    diagnostics = { only_closest = false, info = false, warning = true, error = true },
  },
})
```

Cursor context is off by default; enable it with
`context.cursor_data = { enabled = true, context_lines = 5 }`.
Current and mentioned file display paths are controlled by
`context.current_file.show_full_path` and `context.files.show_full_path`.

## Pickers and completion

File completion asks the server for files by default. To use a local tool,
set `ui.completion.file_sources.preferred_cli_tool` to `fd`, `fdfind`, `rg`, or
`git`; `nil` is the same as `'server'`. Whichever tool is chosen, the others
are tried in turn if it fails. Results are capped at 10 files and displayed
paths at 50 characters. `ignore_patterns` takes Lua patterns, not shell globs;
check the defaults before overriding it.

Snacks pickers inherit your Snacks layout unless you set an override:

```lua
require('opencode').setup({
  ui = { picker = { snacks_layout = { preset = 'select' } } },
})
```

The same field accepts a complete Snacks layout configuration or one of your
custom presets. See [Snacks picker layouts](https://github.com/folke/snacks.nvim/blob/main/docs/picker.md)
for that schema.

Related recipe: [quiet Blink completion](recipes/quiet-blink.md).
Use `~` in input insert mode to add files with your preferred picker.

## Hooks, guards, and diagnostics

[Hooks and events](extensions.md) covers `hooks` and `prompt_guard`.
[Troubleshooting](troubleshooting.md#enable-plugin-logging) covers `logging` and
debug buffers. Logging is off by default; its configured level defaults to `info`.
