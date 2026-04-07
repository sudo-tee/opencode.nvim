local M = {}

local state = require('opencode.state')
local renderer = require('opencode.ui.renderer')

function M.goto_message_by_id(message_id)
  require('opencode.ui.ui').focus_output()
  local windows = state.windows or {}
  local win = windows.output_win
  local buf = windows.output_buf

  if not win or not buf then
    return
  end

  local rendered_msg = renderer.get_rendered_message(message_id)
  if not rendered_msg or not rendered_msg.line_start then
    return
  end
  vim.api.nvim_win_set_cursor(win, { rendered_msg.line_start + 1, 0 })
end

function M.goto_next_message()
  require('opencode.ui.ui').focus_output()
  local windows = state.windows or {}
  local win = windows.output_win
  local buf = windows.output_buf

  if not win or not buf then
    return
  end

  local current_line = vim.api.nvim_win_get_cursor(win)[1]
  local next_message = renderer.get_next_rendered_message(current_line)
  if next_message and next_message.line_start then
    vim.api.nvim_win_set_cursor(win, { next_message.line_start + 1, 0 })
    return
  end

  local line_count = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_win_set_cursor(win, { line_count, 0 })
end

function M.goto_prev_message()
  require('opencode.ui.ui').focus_output()
  local windows = state.windows or {}
  local win = windows.output_win
  local buf = windows.output_buf

  if not win or not buf then
    return
  end

  local current_line = vim.api.nvim_win_get_cursor(win)[1]
  local previous_message = renderer.get_prev_rendered_message(current_line)
  if previous_message and previous_message.line_start then
    vim.api.nvim_win_set_cursor(win, { previous_message.line_start + 1, 0 })
    return
  end

  vim.api.nvim_win_set_cursor(win, { 1, 0 })
end

return M
