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
  keymap = {
    editor = {
      ['<leader>og'] = { 'toggle' },
      ['<leader>oi'] = { 'open_input' },
      ['<leader>oI'] = { 'open_input_new_session' },
      ['<leader>oo'] = { 'open_output' },
      ['<leader>ot'] = { 'toggle_focus' },
      ['<leader>oq'] = { 'close' },
      ['<leader>os'] = { 'select_session' },
      ['<leader>op'] = { 'configure_provider' },
      ['<leader>od'] = { 'diff_open' },
      ['<leader>o]'] = { 'diff_next' },
      ['<leader>o['] = { 'diff_prev' },
      ['<leader>oc'] = { 'diff_close' },
      ['<leader>ora'] = { 'diff_revert_all_last_prompt' },
      ['<leader>ort'] = { 'diff_revert_this_last_prompt' },
      ['<leader>orA'] = { 'diff_revert_all' },
      ['<leader>orT'] = { 'diff_revert_this' },
      ['<leader>orr'] = { 'diff_restore_snapshot_file' },
      ['<leader>orR'] = { 'diff_restore_snapshot_all' },
      ['<leader>oC'] = { 'open_configuration_file' },
      ['<leader>ox'] = { 'swap_position' },
      ['<leader>opa'] = { 'permission_accept' },
      ['<leader>opA'] = { 'permission_accept_all' },
      ['<leader>opd'] = { 'permission_deny' },
    },
    output_window = {
      ['<esc>'] = { 'close' },
      ['<C-c>'] = { 'stop' },
      [']]'] = { 'next_message' },
      ['[['] = { 'prev_message' },
      ['<tab>'] = { 'toggle_pane', mode = { 'n', 'i' } },
      ['<C-i>'] = { 'focus_input' },
      ['<leader>oS'] = { 'select_child_session' },
      ['<leader>oD'] = { 'debug_message' },
      ['<leader>oO'] = { 'debug_output' },
      ['<leader>ods'] = { 'debug_session' },
    },
    input_window = {
      ['<cr>'] = { 'submit_input_prompt', mode = { 'n', 'i' } },
      ['<esc>'] = { 'close' },
      ['<C-c>'] = { 'stop' },
      ['~'] = { 'mention_file', mode = 'i' },
      ['@'] = { 'mention', mode = 'i' },
      ['/'] = { 'slash_commands', mode = 'i' },
      ['<tab>'] = { 'toggle_pane', mode = { 'n', 'i' } },
      ['<up>'] = { 'prev_prompt_history', mode = { 'n', 'i' } },
      ['<down>'] = { 'next_prompt_history', mode = { 'n', 'i' } },
      ['<M-m>'] = { 'switch_mode' },
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
  },
  ui = {
    position = 'right',
    input_position = 'bottom',
    window_width = 0.40,
    input_height = 0.15,
    display_model = true,
    display_context_size = true,
    display_cost = true,
    window_highlight = 'Normal:OpencodeBackground,FloatBorder:OpencodeBorder',
    icons = {
      preset = 'nerdfonts',
      overrides = {},
    },
    loading_animation = {
      frames = { '·', '․', '•', '∙', '●', '⬤', '●', '∙', '•', '․' },
    },
    output = {
      tools = {
        show_output = true,
      },
    },
    input = {
      text = {
        wrap = false,
      },
    },
    completion = {
      file_sources = {
        enabled = true,
        preferred_cli_tool = 'fd',
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
        cache_timeout = 300000,
      },
    },
  },
  context = {
    enabled = true,
    cursor_data = {
      enabled = false,
    },
    diagnostics = {
      info = false,
      warning = true,
      error = true,
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
  },
  debug = {
    enabled = false,
  },
}

M.values = vim.deepcopy(M.defaults)

--- Setup function to initialize or update the configuration
--- @param opts OpencodeConfig
function M.setup(opts)
  opts = opts or {}

  if opts.default_global_keymaps == false then
    M.values.keymap.editor = {}
  end

  -- Check for old keymap structure and migrate to new structure
  if opts.keymap and (opts.keymap.global or opts.keymap.window) then
    vim.notify('opencode.nvim: Legacy keymap format detected. Consider migrating to new format.', vim.log.levels.WARN)

    -- Migrate old global section to editor
    if opts.keymap.global then
      opts.keymap.editor = M.normalize_keymap(opts.keymap.global)
      ---@diagnostic disable-next-line: inject-field
      opts.keymap.global = nil
    end

    -- Migrate old window section to input_window and output_window
    if opts.keymap.window then
      local normalized_window_keymaps = M.normalize_keymap(opts.keymap.window)
      opts.keymap.input_window = normalized_window_keymaps
      opts.keymap.output_window = normalized_window_keymaps
      ---@diagnostic disable-next-line: inject-field
      opts.keymap.window = nil
    end
  end

  -- Merge user options with defaults (deep merge for nested tables)
  for k, v in pairs(opts) do
    if type(v) == 'table' and type(M.values[k]) == 'table' then
      M.values[k] = vim.tbl_deep_extend('force', M.values[k], v)
    else
      M.values[k] = v
    end
  end
end

function M.get(key)
  if key then
    return M.values[key]
  end
  return M.values
end

--- Get the key binding for a specific function in a scope
--- @param scope 'editor'|'input_window'|'output_window'
--- @param function_name string
--- @return string|nil
function M.get_key_for_function(scope, function_name)
  local config_data = M.get()

  local keymap_config = config_data.keymap and config_data.keymap[scope]
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

--- Normalize keymap configuration from old format to new format (exported for testing)
--- @param keymap_config table
--- @return table
function M.normalize_keymap(keymap_config)
  -- Map legacy function names to current API function names
  local legacy_function_map = {
    submit = 'submit_input_prompt',
  }

  local normalized = {}
  for func_name, key in pairs(keymap_config) do
    local api_func_name = legacy_function_map[func_name] or func_name
    normalized[key] = { api_func_name }
  end
  return normalized
end

return M
