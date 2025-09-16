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

local M = {} ---@type OpencodeConfigModule

-- Default configuration
---@type OpencodeConfig
M.defaults = {
  preferred_picker = nil,
  preferred_completion = nil,
  default_global_keymaps = true,
  default_mode = 'build',
  config_file_path = nil,
  keymap = {
    global = {
      toggle = '<leader>og',
      open_input = '<leader>oi',
      open_input_new_session = '<leader>oI',
      open_output = '<leader>oo',
      toggle_focus = '<leader>ot',
      close = '<leader>oq',
      select_session = '<leader>os',
      configure_provider = '<leader>op',
      diff_open = '<leader>od',
      diff_next = '<leader>o]',
      diff_prev = '<leader>o[',
      diff_close = '<leader>oc',
      diff_revert_all_last_prompt = '<leader>ora',
      diff_revert_this_last_prompt = '<leader>ort',
      diff_revert_all = '<leader>orA',
      diff_revert_this = '<leader>orT',
      diff_restore_snapshot_file = '<leader>orr',
      diff_restore_snapshot_all = '<leader>orR',
      open_configuration_file = '<leader>oC',
      swap_position = '<leader>ox', -- Swap Opencode pane left/right
    },
    window = {
      submit = '<cr>',
      submit_insert = '<cr>',
      close = '<esc>',
      stop = '<C-c>',
      next_message = ']]',
      prev_message = '[[',
      mention_file = '~',
      mention = '@',
      slash_commands = '/',
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
    position = 'right',
    input_position = 'bottom',
    window_width = 0.40,
    input_height = 0.15,
    display_model = true,
    display_context_size = true,
    display_cost = true,
    window_highlight = 'Normal:OpencodeBackground,FloatBorder:OpencodeBorder',
    icons = {
      preset = 'emoji',
      overrides = {},
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
