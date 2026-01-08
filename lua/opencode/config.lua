-- Default and user-provided settings for opencode.nvim

---@type OpencodeConfigModule
---@diagnostic disable-next-line: missing-fields
local M = {}
-- Default configuration
---@type OpencodeConfig
M.defaults = {
  preferred_picker = nil,
  preferred_completion = nil,
  default_global_keymaps = true,
  default_mode = 'build',
  legacy_commands = true,
  keymap_prefix = '<leader>o',
  keymap = {
    editor = {
      ['<leader>og'] = { 'toggle', desc = 'Toggle Opencode window' },
      ['<leader>oi'] = { 'open_input', desc = 'Open input window' },
      ['<leader>oI'] = { 'open_input_new_session', desc = 'Open input (new session)' },
      ['<leader>oh'] = { 'select_history', desc = 'Select from history' },
      ['<leader>oo'] = { 'open_output', desc = 'Open output window' },
      ['<leader>ot'] = { 'toggle_focus', desc = 'Toggle focus' },
      ['<leader>oT'] = { 'timeline', desc = 'Session timeline' },
      ['<leader>oq'] = { 'close', desc = 'Close Opencode window' },
      ['<leader>os'] = { 'select_session', desc = 'Select session' },
      ['<leader>oR'] = { 'rename_session', desc = 'Rename session' },
      ['<leader>op'] = { 'configure_provider', desc = 'Configure provider' },
      ['<leader>oz'] = { 'toggle_zoom', desc = 'Toggle zoom' },
      ['<leader>ov'] = { 'paste_image', desc = 'Paste image from clipboard' },
      ['<leader>od'] = { 'diff_open', desc = 'Open diff view' },
      ['<leader>o]'] = { 'diff_next', desc = 'Next diff' },
      ['<leader>o['] = { 'diff_prev', desc = 'Previous diff' },
      ['<leader>oc'] = { 'diff_close', desc = 'Close diff view' },
      ['<leader>ora'] = { 'diff_revert_all_last_prompt', desc = 'Revert all (last prompt)' },
      ['<leader>ort'] = { 'diff_revert_this_last_prompt', desc = 'Revert this (last prompt)' },
      ['<leader>orA'] = { 'diff_revert_all', desc = 'Revert all changes' },
      ['<leader>orT'] = { 'diff_revert_this', desc = 'Revert this change' },
      ['<leader>orr'] = { 'diff_restore_snapshot_file', desc = 'Restore file snapshot' },
      ['<leader>orR'] = { 'diff_restore_snapshot_all', desc = 'Restore all snapshots' },
      ['<leader>ox'] = { 'swap_position', desc = 'Swap window position' },
      ['<leader>oPa'] = { 'permission_accept', desc = 'Accept permission' },
      ['<leader>oPA'] = { 'permission_accept_all', desc = 'Accept all permissions' },
      ['<leader>oPd'] = { 'permission_deny', desc = 'Deny permission' },
      ['<leader>otr'] = { 'toggle_reasoning_output', desc = 'Toggle reasoning output' },
      ['<leader>ott'] = { 'toggle_tool_output', desc = 'Toggle tool output' },
      ['<leader>o/'] = { 'quick_chat', desc = 'Quick chat with current context', mode = { 'n', 'x' } },
    },
    output_window = {
      ['<esc>'] = { 'close' },
      ['<C-c>'] = { 'cancel' },
      [']]'] = { 'next_message' },
      ['[['] = { 'prev_message' },
      ['<tab>'] = { 'toggle_pane', mode = { 'n' } },
      ['i'] = { 'focus_input' },
      ['gr'] = { 'references', desc = 'Browse code references' },
      ['<M-i>'] = { 'toggle_input', mode = { 'n' }, desc = 'Toggle input window' },
      ['<leader>oS'] = { 'select_child_session' },
      ['<leader>oD'] = { 'debug_message' },
      ['<leader>oO'] = { 'debug_output' },
      ['<leader>ods'] = { 'debug_session' },
    },
    input_window = {
      ['<cr>'] = { 'submit_input_prompt', mode = { 'n', 'i' } },
      ['<esc>'] = { 'close' },
      ['<C-c>'] = { 'cancel' },
      ['~'] = { 'mention_file', mode = 'i' },
      ['@'] = { 'mention', mode = 'i' },
      ['/'] = { 'slash_commands', mode = 'i' },
      ['#'] = { 'context_items', mode = 'i' },
      ['<M-v>'] = { 'paste_image', mode = 'i' },
      ['<tab>'] = { 'toggle_pane', mode = { 'n' } },
      ['<up>'] = { 'prev_prompt_history', mode = { 'n', 'i' } },
      ['<down>'] = { 'next_prompt_history', mode = { 'n', 'i' } },
      ['<M-m>'] = { 'switch_mode', mode = { 'n', 'i' } },
      ['<M-i>'] = { 'toggle_input', mode = { 'n', 'i' }, desc = 'Toggle input window' },
      ['gr'] = { 'references', desc = 'Browse code references' },
      ['<leader>oS'] = { 'select_child_session' },
      ['<leader>oD'] = { 'debug_message' },
      ['<leader>oO'] = { 'debug_output' },
      ['<leader>ods'] = { 'debug_session' },
    },
    permission = {
      accept = 'a',
      accept_all = 'A',
      deny = 'd',
    },
    session_picker = {
      rename_session = { '<C-r>' },
      delete_session = { '<C-d>' },
      new_session = { '<C-n>' },
    },
    timeline_picker = {
      undo = { '<C-u>', mode = { 'i', 'n' } },
      fork = { '<C-f>', mode = { 'i', 'n' } },
    },
    history_picker = {
      delete_entry = { '<C-d>', mode = { 'i', 'n' } },
      clear_all = { '<C-X>', mode = { 'i', 'n' } },
    },
    quick_chat = {
      cancel = { '<C-c>', mode = { 'i', 'n' } },
    },
  },
  ui = {
    position = 'right',
    input_position = 'bottom',
    window_width = 0.40,
    zoom_width = 0.8,
    input_height = 0.15,
    picker_width = 100,
    display_model = true,
    display_context_size = true,
    display_cost = true,
    window_highlight = 'Normal:OpencodeBackground,FloatBorder:OpencodeBorder',
    icons = {
      preset = 'nerdfonts',
      overrides = {},
    },
    loading_animation = {
      frames = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' },
    },
    output = {
      rendering = {
        markdown_debounce_ms = 250,
        on_data_rendered = nil,
        event_throttle_ms = 40,
        event_collapsing = true,
      },
      tools = {
        show_output = true,
        show_reasoning_output = true,
      },
      always_scroll_to_bottom = false,
    },
    input = {
      text = {
        wrap = false,
      },
      -- Auto-hide input window when prompt is submitted or focus switches to output window
      auto_hide = false,
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
      only_closest = false, -- If true, only diagnostics for cursor/selection
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
  debug = {
    enabled = false,
    capture_streamed_events = false,
    show_ids = true,
    quick_chat = {
      keep_session = false,
      set_active_session = false,
    },
  },
  prompt_guard = nil,
  hooks = {
    on_file_edited = nil,
    on_session_loaded = nil,
    on_done_thinking = nil,
    on_permission_requested = nil,
  },
  quick_chat = {
    default_model = nil,
    default_agent = nil,
    instructions = nil, -- Use instructions prompt by default
  },
}

M.values = vim.deepcopy(M.defaults)

local function update_keymap_prefix(prefix, default_prefix)
  if prefix == default_prefix or not prefix then
    return
  end

  for category, mappings in pairs(M.values.keymap) do
    local new_mappings = {}
    for key, opts in pairs(mappings) do
      if vim.startswith(key, default_prefix) then
        local new_key = prefix .. key:sub(#default_prefix + 1)

        -- make sure there's not already a mapping for that key
        if not new_mappings[new_key] then
          new_mappings[new_key] = opts
        end
      else
        new_mappings[key] = opts
      end
    end
    M.values.keymap[category] = new_mappings
  end
end

--- Setup function to initialize or update the configuration
--- @param opts OpencodeConfig
function M.setup(opts)
  opts = opts or {}

  M.values = vim.tbl_deep_extend('force', M.values, opts --[[@as OpencodeConfig]])

  if opts.default_global_keymaps == false then
    M.values.keymap.editor = opts.keymap and opts.keymap.editor or {}
  end

  update_keymap_prefix(M.values.keymap_prefix, M.defaults.keymap_prefix)
end

--- Get the key binding for a specific function in a scope
--- @param scope 'editor'|'input_window'|'output_window'
--- @param function_name string
--- @return string|nil
function M.get_key_for_function(scope, function_name)
  local keymap_config = M.values.keymap and M.values.keymap[scope]
  if not keymap_config then
    return nil
  end

  -- All configs are normalized after setup, so only handle new format
  for key, config in pairs(keymap_config) do
    if type(config) == 'string' then
      -- New format: key = 'function_name'
      if config == function_name then
        return key
      end
    elseif type(config) == 'table' then
      -- New format: key = { 'function_name', mode = 'mode' }
      local func = config[1]
      if func == function_name then
        return key
      end
    end
  end
  return nil
end

---@export Config
return setmetatable(M, {
  __index = function(_, key)
    return M.values[key]
  end,
  __newindex = function(_, key, value)
    M.values[key] = value
  end,
  __tostring = function(_)
    return vim.inspect(M.values)
  end,
}) --[[@as OpencodeConfig &  OpencodeConfigModule]]
