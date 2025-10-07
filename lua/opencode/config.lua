-- Default and user-provided settings for opencode.nvim

--- @class OpencodeConfigModule
--- @field defaults OpencodeConfig
--- @field values OpencodeConfig
--- @field setup fun(opts?: OpencodeConfig): nil
--- @field get fun(key: nil): OpencodeConfig
--- @field get fun(key: "preferred_picker"): 'mini.pick' | 'telescope' | 'fzf' | 'snacks' | nil
--- @field get fun(key: "preferred_completion"): 'blink' | 'nvim-cmp' | 'vim_complete' | nil
--- @field get fun(key: "default_mode"): 'build' | 'plan' |
--- @field get fun(key: "default_global_keymaps"): boolean
--- @field get fun(key: "keymap"): OpencodeKeymap
--- @field get fun(key: "ui"): OpencodeUIConfig
--- @field get fun(key: "providers"): OpencodeProviders
--- @field get fun(key: "context"): OpencodeContextConfig
--- @field get fun(key: "debug"): OpencodeDebugConfig
--- @field get_key_for_function fun(scope: 'global'|'window', function_name: string): string|nil
--- @field normalize_keymap fun(keymap_config: table): table

local M = {} ---@type OpencodeConfigModule

-- Default configuration
---@type OpencodeConfig
M.defaults = {
  preferred_picker = nil,
  preferred_completion = nil,
  default_global_keymaps = true,
  default_mode = 'build',
  keymap = {
    global = {
      ['<leader>og'] = 'toggle',
      ['<leader>oi'] = 'open_input',
      ['<leader>oI'] = 'open_input_new_session',
      ['<leader>oo'] = 'open_output',
      ['<leader>ot'] = 'toggle_focus',
      ['<leader>oq'] = 'close',
      ['<leader>os'] = 'select_session',
      ['<leader>op'] = 'configure_provider',
      ['<leader>od'] = 'diff_open',
      ['<leader>o]'] = 'diff_next',
      ['<leader>o['] = 'diff_prev',
      ['<leader>oc'] = 'diff_close',
      ['<leader>ora'] = 'diff_revert_all_last_prompt',
      ['<leader>ort'] = 'diff_revert_this_last_prompt',
      ['<leader>orA'] = 'diff_revert_all',
      ['<leader>orT'] = 'diff_revert_this',
      ['<leader>orr'] = 'diff_restore_snapshot_file',
      ['<leader>orR'] = 'diff_restore_snapshot_all',
      ['<leader>ox'] = 'swap_position',
      ['<leader>opa'] = 'permission_accept',
      ['<leader>opA'] = 'permission_accept_all',
      ['<leader>opd'] = 'permission_deny',
    },
    window = {
      ['<cr>'] = { 'submit_input_prompt', mode = { 'n', 'i' } },
      ['<esc>'] = 'close',
      ['<C-c>'] = 'stop',
      [']]'] = 'next_message',
      ['[['] = 'prev_message',
      ['~'] = { 'mention_file', mode = 'i' },
      ['@'] = { 'mention', mode = 'i' },
      ['/'] = { 'slash_commands', mode = 'i' },
      ['<tab>'] = { 'toggle_pane', mode = { 'n', 'i' } },
      ['<up>'] = { 'prev_prompt_history', mode = { 'n', 'i' } },
      ['<down>'] = { 'next_prompt_history', mode = { 'n', 'i' } },
      ['<M-m>'] = 'switch_mode',
      ['<C-i>'] = 'focus_input',
      ['<leader>oS'] = 'select_child_session',
      ['<leader>oD'] = 'debug_message',
      ['<leader>oO'] = 'debug_output',
      ['<leader>ods'] = 'debug_session',
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

--- Check if a keymap configuration uses the old format (internal use only)
--- @param keymap_config table
--- @return boolean
local function is_old_format(keymap_config)
  for k, v in pairs(keymap_config) do
    if type(k) == 'string' and type(v) == 'string' then
      -- In old format: function_name = key
      -- In new format: key = 'function_name'
      -- Check if the key looks like a function name vs a key binding
      if k:match('^[a-z_]+$') and not k:match('^<.*>$') and not k:match('[%[%](){}]') then
        return true
      else
        return false
      end
    elseif type(k) == 'string' and type(v) == 'table' and (v[1] or v.mode) then
      return false
    end
  end
  return false
end

--- Normalize keymap configuration to new format (internal use only)
--- @param keymap_config table
--- @return table
local function normalize_keymap(keymap_config)
  -- Map legacy function names to current API function names
  local legacy_function_map = {
    submit = 'submit_input_prompt',
  }

  local normalized = {}
  for func_name, key in pairs(keymap_config) do
    -- Translate legacy function names
    local api_func_name = legacy_function_map[func_name] or func_name
    normalized[key] = api_func_name
  end
  return normalized
end

--- Setup function to initialize or update the configuration
--- @param opts OpencodeConfig
function M.setup(opts)
  opts = opts or {}

  if opts.default_global_keymaps == false then
    M.values.keymap.global = {}
  end

  -- Check for old keymap format, normalize, and show deprecation warning
  if opts.keymap then
    if opts.keymap.global and is_old_format(opts.keymap.global) then
      vim.notify(
        'opencode.nvim: Old keymap.global format detected. Please consider migrating to the new format. See documentation for details.',
        vim.log.levels.WARN
      )
      opts.keymap.global = normalize_keymap(opts.keymap.global)
    end
    if opts.keymap.window and is_old_format(opts.keymap.window) then
      vim.notify(
        'opencode.nvim: Old keymap.window format detected. Please consider migrating to the new format. See documentation for details.',
        vim.log.levels.WARN
      )
      opts.keymap.window = normalize_keymap(opts.keymap.window)
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
--- @param scope 'global'|'window'
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

--- Normalize keymap configuration from old format to new format (for testing)
--- @param keymap_config table
--- @return table
function M.normalize_keymap(keymap_config)
  if not is_old_format(keymap_config) then
    return keymap_config
  end
  return normalize_keymap(keymap_config)
end

return M
