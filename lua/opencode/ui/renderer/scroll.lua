local state = require('opencode.state')
local output_window = require('opencode.ui.output_window')

local M = {}

local function with_window_event_autocmds_ignored(fn)
  local previous = vim.o.eventignore
  local ignored = {
    ModeChanged = true,
    WinEnter = true,
    WinLeave = true,
    BufEnter = true,
  }

  for event in previous:gmatch('[^,]+') do
    if event ~= '' then
      ignored[event] = true
    end
  end

  local events = vim.tbl_keys(ignored)
  table.sort(events)
  vim.o.eventignore = table.concat(events, ',')

  local ok, err = pcall(fn)
  vim.o.eventignore = previous
  if not ok then
    error(err)
  end
end

---@param win integer
---@return boolean
local function window_wraps(win)
  local ok, wrap = pcall(vim.api.nvim_get_option_value, 'wrap', { win = win })
  return ok and wrap == true or false
end

---@param win integer
---@return integer
local function get_text_width(win)
  local width = vim.api.nvim_win_get_width(win)
  local ok, wininfo = pcall(vim.fn.getwininfo, win)
  local textoff = ok and wininfo and wininfo[1] and wininfo[1].textoff or 0
  return math.max(1, width - textoff)
end

---@param buf integer
---@param win integer
---@param target_line integer
---@return boolean
local function end_of_target_line_fits_view(buf, win, target_line)
  if not window_wraps(win) then
    return true
  end

  local visible_top = output_window.get_visible_top_line(win)
  local visible_bottom = output_window.get_visible_bottom_line(win)
  if not visible_top or not visible_bottom or target_line < visible_top or target_line > visible_bottom then
    return false
  end

  local height = vim.api.nvim_win_get_height(win)
  local text_width = get_text_width(win)
  local rows = 0
  local line = visible_top

  while line <= target_line do
    local fold_start = vim.api.nvim_win_call(win, function()
      return vim.fn.foldclosed(line)
    end)

    if fold_start ~= -1 then
      rows = rows + 1
      line = vim.api.nvim_win_call(win, function()
        return vim.fn.foldclosedend(line) + 1
      end)
    else
      local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ''
      local display_width = math.max(1, vim.fn.strdisplaywidth(text))
      rows = rows + math.max(1, math.ceil(display_width / text_width))
      line = line + 1
    end

    if rows > height then
      return false
    end
  end

  return true
end

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

  local target_line = output_window.get_effective_bottom_line(buf, line_count)
  if target_line <= 0 then
    return
  end

  local target_text = vim.api.nvim_buf_get_lines(buf, target_line - 1, target_line, false)[1] or ''
  local visible_bottom = output_window.get_visible_bottom_line(win)
  vim.api.nvim_win_set_cursor(win, { target_line, #target_text })

  local needs_bottom_align = not visible_bottom or target_line > visible_bottom
  if not needs_bottom_align and window_wraps(win) then
    needs_bottom_align = not end_of_target_line_fits_view(buf, win, target_line)
  end

  if needs_bottom_align then
    local windows = state.windows
    if windows and vim.api.nvim_get_current_win() == windows.input_win then
      with_window_event_autocmds_ignored(function()
        vim.api.nvim_win_call(win, function()
          vim.cmd('normal! zb')
        end)
      end)
    else
      vim.api.nvim_win_call(win, function()
        vim.cmd('normal! zb')
      end)
    end
  end

  output_window._prev_line_count_by_win[win] = line_count
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

  -- Snapshot the current line count before the buffer write so that
  -- is_at_bottom() can compare cursor position against it after the write.
  local ok, line_count = pcall(vim.api.nvim_buf_line_count, buf)
  if ok and line_count and line_count > 0 then
    output_window._prev_line_count_by_win[win] = line_count
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
