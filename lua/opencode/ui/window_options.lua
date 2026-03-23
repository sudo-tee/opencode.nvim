local M = {}

local config = require('opencode.config')
local state = require('opencode.state')

---@param opt_name string
---@param win integer
local function save_original_window_option(opt_name, win)
  if config.ui.position ~= 'current' then
    return
  end

  if not state.saved_window_options then
    state.ui.set_saved_window_options({})
  end

  if state.saved_window_options[opt_name] ~= nil then
    return
  end

  local ok, original = pcall(vim.api.nvim_get_option_value, opt_name, { win = win })
  if ok then
    state.saved_window_options[opt_name] = original
  end
end

---@param opt_name string
---@param value any
---@param win integer
---@param opts? { save_original?: boolean }
function M.set_window_option(opt_name, value, win, opts)
  opts = opts or {}
  if opts.save_original then
    save_original_window_option(opt_name, win)
  end

  vim.api.nvim_set_option_value(opt_name, value, { win = win, scope = 'local' })
end

---@param opt_name string
---@param value any
---@param buf integer
function M.set_buffer_option(opt_name, value, buf)
  vim.api.nvim_set_option_value(opt_name, value, { buf = buf })
end

return M
