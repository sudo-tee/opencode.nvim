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
  keymap_prefix = '<leader>o',
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
      ['<leader>ox'] = { 'swap_position' },
      ['<leader>oPa'] = { 'permission_accept' },
      ['<leader>oPA'] = { 'permission_accept_all' },
      ['<leader>oPd'] = { 'permission_deny' },
    },
    output_window = {
      ['<esc>'] = { 'close' },
      ['<C-c>'] = { 'stop' },
      [']]'] = { 'next_message' },
      ['[['] = { 'prev_message' },
      ['<tab>'] = { 'toggle_pane', mode = { 'n', 'i' } },
      ['i'] = { 'focus_input' },
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
      ['<M-m>'] = { 'switch_mode', mode = { 'n', 'i' } },
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
      delete_session = { '<C-d>' },
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
    capture_streamed_events = false,
  },
}

M.values = vim.deepcopy(M.defaults)

---Get function names from keymap config, used when normalizing legacy config
---@param keymap_config table
local function get_function_names(keymap_config)
  local names = {}
  for _, config in pairs(keymap_config) do
    if type(config) == 'table' and config[1] then
      table.insert(names, config[1])
    end
  end
  return names
end

function update_keymap_prefix(prefix, default_prefix)
  if prefix == default_prefix or not prefix then
    return
  end

  for category, mappings in pairs(M.values.keymap) do
    local new_mappings = {}
    for key, opts in pairs(mappings) do
      if vim.startswith(key, default_prefix) then
        new_mappings[prefix .. key:sub(#default_prefix + 1)] = opts
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
      opts.keymap.input_window =
        M.normalize_keymap(opts.keymap.window, get_function_names(M.values.keymap.input_window))
      opts.keymap.output_window =
        M.normalize_keymap(opts.keymap.window, get_function_names(M.values.keymap.output_window))
      ---@diagnostic disable-next-line: inject-field
      opts.keymap.window = nil
    end
  end

  -- vim.notify(vim.inspect(opts))
  M.values = vim.tbl_deep_extend('force', M.values, opts --[[@as OpencodeConfig]])
  -- vim.notify(vim.inspect(M.values))

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

---Normalize keymap configuration from old format to new format (exported for testing)
---@param legacy_config table Old config format
---@param filter_functions? table If set, only move functions in this table
---@return table
function M.normalize_keymap(legacy_config, filter_functions)
  local converted = {}
  for func_name, key in pairs(legacy_config) do
    local api_name = func_name == 'submit' and 'submit_input_prompt' or func_name
    if not filter_functions or vim.tbl_contains(filter_functions, api_name) then
      converted[key] = { api_name }
    end
  end
  return converted
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
})
