local M = {}

local state = require('opencode.state')
local output_window = require('opencode.ui.output_window')

local function is_message_header(details)
  local icons = require('opencode.ui.icons')
  local header_user_icon = icons.get('header_user')
  local header_assistant_icon = icons.get('header_assistant')

  if not details or not details.virt_text then
    return false
  end

  local first_virt_text = details.virt_text[1]
  if not first_virt_text then
    return false
  end

  return first_virt_text[1] == header_user_icon or first_virt_text[1] == header_assistant_icon
end

function M.goto_message_by_id(message_id)
  require('opencode.ui.ui').focus_output()
  local windows = state.windows or {}
  local win = windows.output_win
  local buf = windows.output_buf

  if not win or not buf then
    return
  end

  local rendered_msg = require('opencode.ui.renderer').get_rendered_message(message_id)
  if not rendered_msg or not rendered_msg.line_start then
    return
  end
  local sep_offset = #require('opencode.ui.formatter').separator
  vim.api.nvim_win_set_cursor(win, { rendered_msg.line_start + sep_offset, 0 })
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

  local extmarks = vim.api.nvim_buf_get_extmarks(
    buf,
    output_window.namespace,
    { current_line, 0 },
    -1,
    { details = true }
  )

  for _, extmark in ipairs(extmarks) do
    local line = extmark[2] + 1
    local details = extmark[4]

    if line > current_line and is_message_header(details) then
      vim.api.nvim_win_set_cursor(win, { line, 0 })
      return
    end
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

  local extmarks = vim.api.nvim_buf_get_extmarks(
    buf,
    output_window.namespace,
    0,
    { current_line - 1, -1 },
    { details = true }
  )

  for i = #extmarks, 1, -1 do
    local extmark = extmarks[i]
    local line = extmark[2] + 1
    local details = extmark[4]

    if line < current_line and is_message_header(details) then
      vim.api.nvim_win_set_cursor(win, { line, 0 })
      return
    end
  end
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
end

return M
