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
  keymap = {
    -- Global keymaps (all use { 'n', 'v' } modes by default)
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
      submit = { '<cr>', { 'n', 'i' } }, -- Submit prompt (works in both normal and insert modes)
      close = { '<esc>', 'n' },
      stop = { '<C-c>', 'n' },
      next_message = { ']]', 'n' },
      prev_message = { '[[', 'n' },
      mention_file = { '~', 'i' },
      mention = { '@', 'i' },
      slash_commands = { '/', 'i' },
      toggle_pane = { '<tab>', { 'n', 'i' } },
      prev_prompt_history = { '<up>', { 'n', 'i' } },
      next_prompt_history = { '<down>', { 'n', 'i' } },
      switch_mode = { '<M-m>', { 'n', 'i' } },
      focus_input = { '<C-i>', 'n' },
      select_child_session = { '<leader>oS', 'n' },
      debug_message = { '<leader>oD', 'n' },
      debug_output = { '<leader>oO', 'n' },
      debug_session = { '<leader>ods', 'n' },
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

  -- Handle backward compatibility for submit_insert
  if M.values.keymap and M.values.keymap.window and M.values.keymap.window.submit_insert then
    vim.notify(
      'opencode.nvim: submit_insert keymap is deprecated. Use submit = { key, { "n", "i" } } instead.',
      vim.log.levels.WARN
    )
    
    -- If user has submit_insert but not submit, migrate submit_insert to submit with multi-mode
    if not opts.keymap or not opts.keymap.window or not opts.keymap.window.submit then
      local submit_insert_keymap = M.values.keymap.window.submit_insert
      if type(submit_insert_keymap) == 'string' then
        M.values.keymap.window.submit = { submit_insert_keymap, { 'n', 'i' } }
      elseif type(submit_insert_keymap) == 'table' and submit_insert_keymap[1] then
        M.values.keymap.window.submit = { submit_insert_keymap[1], { 'n', 'i' } }
      end
    end
    
    -- Remove submit_insert from final config
    M.values.keymap.window.submit_insert = nil
  end
end

function M.get(key)
  if key then
    return M.values[key]
  end
  return M.values
end

return M
