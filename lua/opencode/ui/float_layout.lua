local config = require('opencode.config')
local state = require('opencode.state')

local M = {}

---@param value number|nil
---@param total integer
---@param fallback number
---@return integer
local function resolve_dimension(value, total, fallback)
  local resolved = value or fallback
  if resolved > 0 and resolved <= 1 then
    return math.floor(total * resolved)
  end
  return math.floor(resolved)
end

---@param value number|nil
---@param total integer
---@param size integer
---@return integer
local function resolve_position(value, total, size)
  if value == nil then
    return math.floor((total - size) / 2)
  end
  if value > 0 and value <= 1 then
    return math.floor(total * value)
  end
  return math.floor(value)
end

---@param value integer
---@param min_value integer
---@param max_value integer
---@return integer
local function clamp(value, min_value, max_value)
  return math.min(max_value, math.max(min_value, value))
end

---@param windows OpencodeWindowState|nil
---@return integer
local function input_height(windows)
  local line_count = 1
  if windows and windows.input_buf and vim.api.nvim_buf_is_valid(windows.input_buf) then
    line_count = vim.api.nvim_buf_line_count(windows.input_buf)
  end

  local min_height = math.max(1, math.floor(vim.o.lines * config.ui.input.min_height))
  local max_height = math.max(min_height, math.floor(vim.o.lines * config.ui.input.max_height))
  return clamp(line_count, min_height, max_height)
end

---@param windows OpencodeWindowState|nil
---@return vim.api.keyset.win_config
local function base_config(windows)
  local float = config.ui.float or {}
  local width
  if windows and windows.saved_width_ratio then
    width = math.floor(vim.o.columns * windows.saved_width_ratio)
    windows.saved_width_ratio = nil
  elseif state.pre_zoom_width then
    width = math.floor(vim.o.columns * config.ui.zoom_width)
  else
    width = resolve_dimension(float.width, vim.o.columns, 0.95)
  end
  local height = resolve_dimension(float.height, vim.o.lines, 0.9)

  return {
    relative = 'editor',
    width = width,
    height = height,
    row = resolve_position(float.row, vim.o.lines, height),
    col = resolve_position(float.col, vim.o.columns, width),
    style = 'minimal',
    border = float.border,
  }
end

---@param windows OpencodeWindowState|nil
---@param show_input boolean
---@return vim.api.keyset.win_config output_config
function M.window_configs(windows, show_input)
  local float = config.ui.float or {}
  local base = base_config(windows)
  local prompt_height = show_input and input_height(windows) or 0
  local gap = show_input and (float.gap or 1) or 0
  local output_height = math.max(1, base.height - prompt_height - gap)

  local output_config = vim.tbl_deep_extend('force', base, {
    height = output_height,
    zindex = float.zindex or 40,
  })

  if not show_input then
    return output_config, nil
  end

  local input_config = vim.tbl_deep_extend('force', base, {
    height = prompt_height,
    zindex = (float.zindex or 40) + 1,
  })

  if config.ui.input_position == 'top' then
    output_config.row = base.row + prompt_height + gap
  else
    input_config.row = base.row + output_height + gap
  end

  return output_config, input_config
end

---@param buf integer
---@param enter boolean
---@param win_config vim.api.keyset.win_config
---@return integer
function M.open_win(buf, enter, win_config)
  local win = vim.api.nvim_open_win(buf, enter, win_config)
  local float = config.ui.float or {}
  for opt, value in pairs(float.opts or {}) do
    pcall(vim.api.nvim_set_option_value, opt, value, { win = win, scope = 'local' })
  end
  return win
end

---@param windows OpencodeWindowState|nil
---@param show_input boolean
function M.update(windows, show_input)
  if not windows or not windows.output_win or not vim.api.nvim_win_is_valid(windows.output_win) then
    return
  end

  local output_config, input_config = M.window_configs(windows, show_input)
  pcall(vim.api.nvim_win_set_config, windows.output_win, output_config)

  if show_input and input_config and windows.input_win and vim.api.nvim_win_is_valid(windows.input_win) then
    pcall(vim.api.nvim_win_set_config, windows.input_win, input_config)
  end

  if windows.footer_win and vim.api.nvim_win_is_valid(windows.footer_win) then
    require('opencode.ui.footer').update_window(windows)
  end
end

return M
