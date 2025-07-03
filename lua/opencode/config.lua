-- Default and user-provided settings for opencode.nvim

--- @class OpencodeKeymapGlobal
--- @field toggle string
--- @field open_input string
--- @field open_input_new_session string
--- @field open_output string
--- @field toggle_focus string
--- @field close string
--- @field toggle_fullscreen string
--- @field select_session string
--- @field opencode_mode_chat string
--- @field opencode_mode_auto string
--- @field configure_provider string
--- @field diff_open string
--- @field diff_next string
--- @field diff_prev string
--- @field diff_close string
--- @field diff_revert_all string
--- @field diff_revert_this string

--- @class OpencodeKeymapWindow
--- @field submit string
--- @field submit_insert string
--- @field close string
--- @field stop string
--- @field next_message string
--- @field prev_message string
--- @field mention_file string
--- @field toggle_pane string
--- @field prev_prompt_history string
--- @field next_prompt_history string
--- @field focus_input string

--- @class OpencodeKeymap
--- @field global OpencodeKeymapGlobal
--- @field window OpencodeKeymapWindow

--- @class OpencodeUIConfig
--- @field window_width number
--- @field input_height number
--- @field fullscreen boolean
--- @field layout string
--- @field floating_height number
--- @field display_model boolean

--- @class OpencodeContextConfig
--- @field cursor_data boolean

--- @class OpencodeProviders
--- @field [string] string[]

--- @class OpencodeConfig
--- @field prefered_picker 'telescope' | 'fzf' | 'mini.pick' | 'snacks' | nil
--- @field default_global_keymaps boolean
--- @field keymap OpencodeKeymap
--- @field ui OpencodeUIConfig
--- @field providers OpencodeProviders
--- @field context OpencodeContextConfig

--- @generic K: '"prefered_picker"|"default_global_keymaps"|"keymap"|"ui"|"providers"|"context"'

--- @class OpencodeModule
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

local M = {} ---@type OpencodeModule

-- Default configuration
M.defaults = {
  prefered_picker = nil,
  default_global_keymaps = true,
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
      opencode_mode_chat = '<leader>omc',
      opencode_mode_auto = '<leader>oma',
      configure_provider = '<leader>op',
      diff_open = '<leader>od',
      diff_next = '<leader>o]',
      diff_prev = '<leader>o[',
      diff_close = '<leader>oc',
      diff_revert_all = '<leader>ora',
      diff_revert_this = '<leader>ort',
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
      focus_input = '<C-i>',
    },
  },
  ui = {
    window_width = 0.35,
    input_height = 0.15,
    fullscreen = false,
    layout = 'right',
    floating_height = 0.8,
    display_model = true,
  },
  context = {
    cursor_data = false,
  },
}

M.values = vim.deepcopy(M.defaults)

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
