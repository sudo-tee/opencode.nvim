local config = require('opencode.config')
local state = require('opencode.state')
local output_window = require('opencode.ui.output_window')

local M = {}

---@return integer|nil
function M.get_output_win()
  local windows = state.windows
  local win = windows and windows.output_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  return win
end

---Move the cursor in `win` to the last line of `buf` and scroll so it's visible.
---@param win integer
---@param buf integer
function M.scroll_win_to_bottom(win, buf)
  local line_count = vim.api.nvim_buf_line_count(buf)
  if line_count == 0 then
    return
  end
  local last_line = vim.api.nvim_buf_get_lines(buf, line_count - 1, line_count, false)[1] or ''
  vim.api.nvim_win_set_cursor(win, { line_count, #last_line })
  vim.api.nvim_win_call(win, function()
    vim.cmd('normal! zb')
  end)
end

---@param buf integer|nil
---@return { win: integer, follow: boolean }|nil
function M.pre_flush(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end

  local win = M.get_output_win()
  if not win or vim.api.nvim_win_get_buf(win) ~= buf then
    return nil
  end

  return {
    win = win,
    follow = output_window.is_at_bottom(win),
  }
end

---@param snapshot { win: integer, follow: boolean }|nil
---@param buf integer|nil
function M.post_flush(snapshot, buf)
  if not snapshot or not snapshot.follow or not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if not vim.api.nvim_win_is_valid(snapshot.win) or vim.api.nvim_win_get_buf(snapshot.win) ~= buf then
    return
  end
  M.scroll_win_to_bottom(snapshot.win, buf)
end

return M
