local M = {}

local state = require('opencode.state')
local config = require('opencode.config')
local renderer = require('opencode.ui.renderer')

---@param win integer
local function mark_jump_position(win)
  pcall(vim.api.nvim_win_call, win, function()
    vim.cmd([[noau normal! m']])
  end)
end

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
  mark_jump_position(win)
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
    mark_jump_position(win)
    vim.api.nvim_win_set_cursor(win, { next_message.line_start + 1, 0 })
    return
  end

  local line_count = vim.api.nvim_buf_line_count(buf)
  mark_jump_position(win)
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
    mark_jump_position(win)
    vim.api.nvim_win_set_cursor(win, { previous_message.line_start + 1, 0 })
    return
  end

  mark_jump_position(win)
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

  -- Mirror `gg` in output_window.setup_keymaps: under lazy render the target
  -- message may not yet have a line_start, so force a full render first.
  renderer.load_all_messages()

  local current_line = vim.api.nvim_win_get_cursor(win)[1]
  local next_message = renderer.get_next_user_message(current_line)
  if next_message and next_message.line_start then
    mark_jump_position(win)
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

  renderer.load_all_messages()

  local current_line = vim.api.nvim_win_get_cursor(win)[1]
  local previous_message = renderer.get_prev_user_message(current_line)
  if previous_message and previous_message.line_start then
    mark_jump_position(win)
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
end

---Open a file in the current window without triggering BufRead/BufNew autocmds.
---Falls back to :edit if the file isn't loaded in any buffer yet.
---@param path string
---@return boolean
local function open_silent(path)
  local escaped = vim.fn.fnameescape(path)
  if not pcall(function()
    vim.cmd('buffer ' .. escaped)
  end) then
    return pcall(function()
      vim.cmd('edit ' .. escaped)
    end)
  end
  return true
end

local function open_at(win, path, line, col)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  vim.api.nvim_set_current_win(win)
  if not open_silent(path) then
    return false
  end
  if line then
    local buf = vim.api.nvim_win_get_buf(win)
    local line_count = vim.api.nvim_buf_line_count(buf)
    local target_line = math.max(1, math.min(line, line_count))
    local target_col = 0
    if col then
      local target_lines = vim.api.nvim_buf_get_lines(buf, target_line - 1, target_line, false)
      local line_text = target_lines[1] or ''
      target_col = math.max(0, math.min(col - 1, math.max(#line_text - 1, 0)))
    end
    mark_jump_position(win)
    pcall(vim.api.nvim_win_set_cursor, win, { target_line, target_col })
    vim.cmd('normal! zz')
  end
  return true
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

---@param path string
---@param line? number
---@param col? number
---@return boolean
function M.navigate_to_location(path, line, col)
  local resolved_path = resolve_path(path)
  if not resolved_path then
    return false
  end
  local target_win = best_target_win()
  local windows = state.windows
  if windows and windows.position == 'current' and target_win == windows.output_win then
    require('opencode.ui.ui').hide_visible_windows(windows)
  end
  return open_at(target_win, resolved_path, line, col)
end

function M.resolve_target_at_cursor()
  local windows = state.windows or {}
  local win = windows.output_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(win)
  return renderer.get_target_at_position(cursor[1], cursor[2])
end

local function format_symbol_target(target, width)
  local location = target.path
  if target.line then
    location = location .. ':' .. target.line
    if target.col then
      location = location .. ':' .. target.col
    end
  end
  local kind = target.kind and (' [' .. target.kind .. ']') or ''
  return require('opencode.ui.base_picker').create_time_picker_item(
    target.token .. kind .. ' ' .. location,
    nil,
    nil,
    width
  )
end

local function pick_symbol_target(targets)
  return require('opencode.ui.base_picker').pick({
    items = targets,
    format_fn = format_symbol_target,
    actions = {},
    callback = function(selected)
      if selected then
        M.navigate_to_location(selected.path, selected.line, selected.col)
      end
    end,
    title = 'Symbol References (' .. #targets .. ')',
    width = config.ui.picker_width,
    preview = 'file',
    layout_opts = config.ui.picker,
  })
end

local function target_at_cursor(filter)
  local windows = state.windows or {}
  local win = windows.output_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(win)
  return renderer.get_target_at_position(cursor[1], cursor[2], filter)
end

local function jump_to_symbol_target(target)
  if not target.token then
    return
  end

  local symbol_snapshot = require('opencode.ui.symbol_snapshot')
  local targets =
    symbol_snapshot.targets_for_token(symbol_snapshot.new_cycle(), target.token, target.candidate_files or {})
  if #targets == 0 then
    vim.notify('No symbol target found: ' .. target.token, vim.log.levels.INFO)
    return
  end

  if #targets == 1 then
    local resolved = targets[1]
    M.navigate_to_location(resolved.path, resolved.line, resolved.col)
    return
  end

  pick_symbol_target(targets)
end

local function jump_to_rendered_target(target)
  if target.kind == 'file' or target.kind == 'diff' then
    M.navigate_to_location(target.path, target.line, target.col)
    return
  end

  if target.kind == 'symbol' then
    jump_to_symbol_target(target)
  end
end

function M.jump_to_target_at_cursor()
  local target = target_at_cursor()
  if target then
    jump_to_rendered_target(target)
  end
end

function M.jump_to_file_at_cursor()
  local target = target_at_cursor(function(candidate)
    return candidate.kind == 'file' or candidate.kind == 'diff'
  end)
  if not target then
    return
  end
  jump_to_rendered_target(target)
end

return M
