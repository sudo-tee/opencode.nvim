local M = {}

local state = require('opencode.state')
local session_formatter = require('opencode.ui.session_formatter')
local SEPARATOR_TEXT = session_formatter.separator[1]

local function re_focus()
  vim.cmd("normal! zt")
end

function M.goto_next_message()
  require('opencode.ui.ui').focus_output()
  local windows = state.windows
  local win = windows.output_win
  local buf = windows.output_buf

  local current_line = vim.api.nvim_win_get_cursor(win)[1]
  local line_count = vim.api.nvim_buf_line_count(buf)

  for i = current_line, line_count do
    local line = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1]
    if line == SEPARATOR_TEXT then
      vim.api.nvim_win_set_cursor(win, { i + 1, 0 })
      re_focus()
      return
    end
  end
end

function M.goto_prev_message()
  require('opencode.ui.ui').focus_output()
  local windows = state.windows
  local win = windows.output_win
  local buf = windows.output_buf
  local current_line = vim.api.nvim_win_get_cursor(win)[1]
  local current_message_start = nil

  -- Find if we're at a message start
  local at_message_start = false
  if current_line > 1 then
    local prev_line = vim.api.nvim_buf_get_lines(buf, current_line - 2, current_line - 1, false)[1]
    at_message_start = prev_line == SEPARATOR_TEXT
  end

  -- Find current message start
  for i = current_line - 1, 1, -1 do
    local line = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1]
    if line == SEPARATOR_TEXT then
      current_message_start = i + 1
      break
    end
  end

  -- Go to first line if no separator found
  if not current_message_start then
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    re_focus()
    return
  end

  -- If not at message start, go to current message start
  if not at_message_start and current_line > current_message_start then
    vim.api.nvim_win_set_cursor(win, { current_message_start, 0 })
    re_focus()
    return
  end

  -- Find previous message start
  for i = current_message_start - 2, 1, -1 do
    local line = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1]
    if line == SEPARATOR_TEXT then
      vim.api.nvim_win_set_cursor(win, { i + 1, 0 })
      re_focus()
      return
    end
  end

  -- If no previous message, go to first line
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  re_focus()
end

return M
