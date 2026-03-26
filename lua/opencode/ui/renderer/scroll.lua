local config = require('opencode.config')
local state = require('opencode.state')

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

---@param win integer
---@param buf integer
---@return boolean
local function is_at_bottom(win, buf)
  if config.ui.output.always_scroll_to_bottom then
    return true
  end

  local ok_count, line_count = pcall(vim.api.nvim_buf_line_count, buf)
  if not ok_count or line_count == 0 then
    return true
  end

  local ok_view, view = pcall(vim.api.nvim_win_call, win, vim.fn.winsaveview)
  if not ok_view or type(view) ~= 'table' then
    return false
  end

  local topline = view.topline or 1
  local botline = view.botline or topline
  return botline >= line_count or topline > line_count
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
    follow = is_at_bottom(win, buf),
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

  local line_count = vim.api.nvim_buf_line_count(buf)
  if line_count == 0 then
    return
  end

  local last_line = vim.api.nvim_buf_get_lines(buf, line_count - 1, line_count, false)[1] or ''
  vim.api.nvim_win_set_cursor(snapshot.win, { line_count, #last_line })
  vim.api.nvim_win_call(snapshot.win, function()
    vim.cmd('normal! zb')
  end)
end

return M
