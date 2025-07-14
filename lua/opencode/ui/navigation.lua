local M = {}

local state = require('opencode.state')
local session_formatter = require('opencode.ui.session_formatter')

local function re_focus()
  vim.cmd('normal! zt')
end

function M.goto_next_message()
  require('opencode.ui.ui').focus_output()
  local windows = state.windows
  local win = windows.output_win
  local buf = windows.output_buf
  local all_metadata = session_formatter.output:get_all_metadata()

  local current_line = vim.api.nvim_win_get_cursor(win)[1]
  local line_count = vim.api.nvim_buf_line_count(buf)
  local current = session_formatter.get_message_at_line(current_line)
  local current_idx = current and current.msg_idx or 0

  for i = current_line, line_count do
    local meta = all_metadata[i]
    if meta and meta.msg_idx > current_idx and meta.type == 'header' then
      vim.api.nvim_win_set_cursor(win, { i, 0 })
      re_focus()
      return
    end
  end
end

function M.goto_prev_message()
  require('opencode.ui.ui').focus_output()
  local windows = state.windows
  local win = windows.output_win
  local all_metadata = session_formatter.output:get_all_metadata()

  local current_line = vim.api.nvim_win_get_cursor(win)[1]
  local current = session_formatter.get_message_at_line(current_line)
  local current_idx = current and current.msg_idx or 0

  for i = current_line - 1, 1, -1 do
    local meta = all_metadata[i]
    if meta and meta.msg_idx < current_idx and meta.type == 'header' then
      vim.api.nvim_win_set_cursor(win, { i, 0 })
      re_focus()
      return
    end
  end

  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  re_focus()
end

return M
