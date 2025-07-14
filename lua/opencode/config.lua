-- Default and user-provided settings for opencode.nvim

--- @class OpencodeConfigModule
--- @field defaults OpencodeConfig
--- @field values OpencodeConfig
--- @field setup fun(opts?: OpencodeConfig): nil
--- @field get fun(key: nil): OpencodeConfig
--- @field get fun(key: "prefered_picker"): 'mini.pick' | 'telescope' | 'fzf' | 'snacks' | nil
--- @field get fun(key: "default_global_keymaps"): boolean
--- @field get fun(key: "keymap"): OpencodeKeymap
--- @field get fun(key: "ui"): OpencodeUIConfig
--- @field get fun(key: "providers"): OpencodeProviders
--- @field get fun(key: "context"): OpencodeContextConfig
--- @field get fun(key: "debug"): OpencodeDebugConfig

local M = {} ---@type OpencodeConfigModule

-- Default configuration
---@type OpencodeConfig
M.defaults = {
  prefered_picker = nil,
  default_global_keymaps = true,
  default_mode = 'build',
  keymap = {
    global = {
      toggle = '<leader>og',
      open_input = '<leader>oi',
      open_input_new_session = '<leader>oI',
      open_output = '<leader>oo',
      toggle_focus = '<leader>ot',
      close = '<leader>oq',
      toggle_fullscreen = '<leader>of',
      select_session = '<leader>os',
      configure_provider = '<leader>op',
      diff_open = '<leader>od',
      diff_next = '<leader>o]',
      diff_prev = '<leader>o[',
      diff_close = '<leader>oc',
      diff_revert_all = '<leader>ora',
      diff_revert_this = '<leader>ort',
      open_configuration_file = '<leader>oc',
    },
    window = {
      submit = '<cr>',
      submit_insert = '<cr>',
      close = '<esc>',
      stop = '<C-c>',
      next_message = ']]',
      prev_message = '[[',
      mention_file = '@',
      toggle_pane = '<tab>',
      prev_prompt_history = '<up>',
      next_prompt_history = '<down>',
      switch_mode = '<M-m>',
      focus_input = '<C-i>',
      debug_message = '<leader>oD',
      debug_output = '<leader>oO',
    },
  },
  ui = {
    floating = false,
    window_width = 0.40,
    input_height = 0.15,
    fullscreen = false,
    layout = 'right',
    floating_height = 0.8,
    display_model = true,
    window_highlight = 'Normal:OpencodeBackground,FloatBorder:OpencodeBorder',
  },
  context = {
    cursor_data = false,
    diagnostics = {
      info = false,
      warning = true,
      error = true,
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
    M.values.keymap.global = {}
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

return M
