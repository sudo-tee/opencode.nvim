local M = {}

local state = require('opencode.state')
local renderer = require('opencode.ui.renderer')
local output_window = require('opencode.ui.output_window')

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

function M.goto_next_user_message()
  require('opencode.ui.ui').focus_output()
  local windows = state.windows or {}
  local win = windows.output_win
  local buf = windows.output_buf

  if not win or not buf then
    return
  end

  local current_line = vim.api.nvim_win_get_cursor(win)[1]
  local next_message = renderer.get_next_user_message(current_line)
  if next_message and next_message.line_start then
    vim.api.nvim_win_set_cursor(win, { next_message.line_start + 1, 0 })
    return
  end

  vim.notify('No next user message', vim.log.levels.INFO)
end

function M.goto_prev_user_message()
  require('opencode.ui.ui').focus_output()
  local windows = state.windows or {}
  local win = windows.output_win
  local buf = windows.output_buf

  if not win or not buf then
    return
  end

  local current_line = vim.api.nvim_win_get_cursor(win)[1]
  local previous_message = renderer.get_prev_user_message(current_line)
  if previous_message and previous_message.line_start then
    vim.api.nvim_win_set_cursor(win, { previous_message.line_start + 1, 0 })
    return
  end

  vim.notify('No previous user message', vim.log.levels.INFO)
end

---@param raw string
local function resolve_path(raw)
  if vim.uv.fs_stat(raw) then
    return raw
  end
  local absolute = vim.fn.fnamemodify(raw, ':p')
  if vim.uv.fs_stat(absolute) then
    return absolute
  end
  local found = vim.fn.findfile(raw, '.;')
  if found ~= '' then
    return found
  end
end

---Resolve file and line number at cursor position in the output buffer.
---@return { path: string, line: number? }?
function M.resolve_file_at_cursor()
  local windows = state.windows or {}
  local win = windows.output_win
  local buf = windows.output_buf

  if not win or not buf or not vim.api.nvim_win_is_valid(win) then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(win)
  local line_num = cursor[1]
  local line = vim.api.nvim_buf_get_lines(buf, line_num - 1, line_num, false)[1]

  if not line then
    return nil
  end

  -- 1. Check for markdown-style file links: [`path`](path)
  local path = line:match('%[`([^`]+)%`%]%([^%)]+%)')
  if path then
    return { path = path }
  end

  -- 2. Check for file:// style links: `file://path/to/file.lua:line`
  local f_path, f_line = line:match('`file://([^:`]+):?(%d*)`')
  if f_path then
    return { path = f_path, line = tonumber(f_line) }
  end

  -- 3. Check for action lines: **icon tool** `path`
  path = line:match('%*%*.-%*%*%s+`([^`]+)`')
  if path then
    return { path = path }
  end

  -- 4. Check for diff hunk: look for the nearest file path upwards
  local file_path = nil
  for i = line_num, 1, -1 do
    local l = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1]
    if l then
      local p = l:match('%[`([^`]+)%`%]%([^%)]+%)') or l:match('%*%*.-%*%*%s+`([^`]+)`')
      if p then
        file_path = p
        break
      end
    end
  end

  if not file_path then
    return nil
  end

  -- Check if we are on a diff line with a line number in the gutter
  local ns = output_window.namespace
  local extmarks = vim.api.nvim_buf_get_extmarks(buf, ns, { line_num - 1, 0 }, { line_num - 1, -1 }, { details = true })
  local ln ---@type number?
  for _, extmark in ipairs(extmarks) do
    local details = extmark[4]
    if details and details.virt_text then
      for _, vt in ipairs(details.virt_text) do
        local val = tonumber(vim.trim(vt[1]))
        if val then
          ln = val
          break
        end
      end
    end
    if ln then
      break
    end
  end

  return { path = file_path, line = ln }
end

---Open a file in the current window without triggering BufRead/BufNew autocmds.
---Falls back to :edit if the file isn't loaded in any buffer yet.
---@param path string
local function open_silent(path)
  local escaped = vim.fn.fnameescape(path)
  if not pcall(vim.cmd, 'buffer ' .. escaped) then
    pcall(vim.cmd, 'edit ' .. escaped)
  end
end

local function open_at(win, path, line)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  vim.api.nvim_set_current_win(win)
  open_silent(path)
  if line then
    local buf = vim.api.nvim_win_get_buf(win)
    local line_count = vim.api.nvim_buf_line_count(buf)
    line = math.min(line, line_count)
    pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
  end
end

local function best_target_win()
  local w = state.last_code_win_before_opencode
  if w and vim.api.nvim_win_is_valid(w) then
    return w
  end
  local alt = vim.fn.win_getid(vim.fn.winnr('#'))
  if alt ~= 0 and vim.api.nvim_win_is_valid(alt) then
    return alt
  end
end

function M.jump_to_file_at_cursor()
  local resolved = M.resolve_file_at_cursor()
  if not resolved then
    return
  end
  local path = resolve_path(resolved.path)
  if not path then
    return
  end
  open_at(best_target_win(), path, resolved.line)
end

return M
