local M = {}

local state = require('opencode.state')
local config = require('opencode.config')
local renderer = require('opencode.ui.renderer')
local output_window = require('opencode.ui.output_window')
local symbol_tokens = require('opencode.ui.symbol_tokens')

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

  -- Mirror `gg` in output_window.setup_keymaps: under lazy render the target
  -- message may not yet have a line_start, so force a full render first.
  renderer.load_all_messages()

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

  renderer.load_all_messages()

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

local function parse_path_location(raw)
  if raw:match('^%a[%w+.-]*://') and not raw:match('^file://') then
    return nil
  end

  local path = raw:gsub('^file://', '')
  local line, col
  local p, l, c = path:match('^(.-):(%d+):(%d+)$')
  if p then
    path, line, col = p, tonumber(l), tonumber(c)
  else
    p, l = path:match('^(.-):(%d+)$')
    if p then
      path, line = p, tonumber(l)
    end
  end

  if path == '' then
    return nil
  end

  return { path = path, line = line, col = col }
end

local function contains_col(start_pos, end_pos, col)
  return col >= start_pos - 1 and col <= end_pos - 1
end

local function add_file_candidate(candidates, line, pattern, path_capture_index)
  path_capture_index = path_capture_index or 2
  local captures = { line:match(pattern) }
  while #captures > 0 do
    local start_pos = captures[1]
    local end_pos = captures[#captures] - 1
    local raw = captures[path_capture_index]
    table.insert(candidates, {
      start_pos = start_pos,
      end_pos = end_pos,
      target = parse_path_location(raw),
    })
    local next_start = end_pos + 2
    captures = { line:match(pattern, next_start) }
  end
end

local function file_target_at_col(line, col)
  local candidates = {}

  add_file_candidate(candidates, line, '()%[%`([^`]+)%`%]%([^%)]+%)()')
  add_file_candidate(candidates, line, '()%`([^`\n]+%.%w+:?%d*:?%d*)%`()')
  add_file_candidate(candidates, line, '()file://([%S]+%.%w+:?%d*:?%d*)()')
  add_file_candidate(candidates, line, '()%*%*.-%*%*%s+%`([^`]+)%`()')
  add_file_candidate(candidates, line, '()([%w_./%-]+/[%w_./%-]*%.%w+:?%d*:?%d*)()')
  add_file_candidate(candidates, line, '()([%w_%-]+%.%w+:?%d*:?%d*)()')

  for _, candidate in ipairs(candidates) do
    if
      candidate.target
      and contains_col(candidate.start_pos, candidate.end_pos, col)
      and resolve_path(candidate.target.path)
    then
      return candidate.target
    end
  end
end

local function first_file_target(line)
  local max_col = math.max(#line - 1, 0)
  for col = 0, max_col do
    local target = file_target_at_col(line, col)
    if target then
      return target
    end
  end
end

local function symbol_token_at_col(line, col)
  return symbol_tokens.at_col(line, col)
end

local function cursor_symbol_token()
  local windows = state.windows or {}
  local win = windows.output_win
  local buf = windows.output_buf

  if not win or not buf or not vim.api.nvim_win_is_valid(win) then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(win)
  local line = vim.api.nvim_buf_get_lines(buf, cursor[1] - 1, cursor[1], false)[1]
  if not line then
    return nil
  end

  return symbol_token_at_col(line, cursor[2])
end

local function diff_line_number(buf, line_num)
  local ns = output_window.namespace
  local extmarks = vim.api.nvim_buf_get_extmarks(buf, ns, { line_num - 1, 0 }, { line_num - 1, -1 }, { details = true })
  for _, extmark in ipairs(extmarks) do
    local details = extmark[4]
    local virt_text = details and details.virt_text
    if virt_text then
      local gutter = virt_text[1] and virt_text[1][1]
      local sign = virt_text[2] and virt_text[2][1]
      if sign == '-' then
        return nil
      end
      if sign == '+' or sign == ' ' then
        return tonumber(vim.trim(gutter or ''))
      end
    end
  end
end

---Resolve file and line number at cursor position in the output buffer.
---@return { path: string, line: number?, col: number? }?
function M.resolve_file_at_cursor()
  local windows = state.windows or {}
  local win = windows.output_win
  local buf = windows.output_buf

  if not win or not buf or not vim.api.nvim_win_is_valid(win) then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(win)
  local line_num = cursor[1]
  local col = cursor[2]
  local line = vim.api.nvim_buf_get_lines(buf, line_num - 1, line_num, false)[1]

  if not line then
    return nil
  end

  local target = file_target_at_col(line, col)
  if target then
    return target
  end

  local file_path = nil
  for i = line_num, 1, -1 do
    local l = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1]
    if l then
      local found = first_file_target(l)
      if found then
        file_path = found.path
        break
      end
    end
  end

  if not file_path then
    return nil
  end

  local ln = diff_line_number(buf, line_num)
  if not ln then
    return nil
  end

  return { path = file_path, line = ln }
end

---Open a file in the current window without triggering BufRead/BufNew autocmds.
---Falls back to :edit if the file isn't loaded in any buffer yet.
---@param path string
local function open_silent(path)
  local escaped = vim.fn.fnameescape(path)
  if not pcall(function()
    vim.cmd('buffer ' .. escaped)
  end) then
    pcall(function()
      vim.cmd('edit ' .. escaped)
    end)
  end
end

local function open_at(win, path, line, col)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  vim.api.nvim_set_current_win(win)
  open_silent(path)
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
    pcall(vim.api.nvim_win_set_cursor, win, { target_line, target_col })
    vim.cmd('normal! zz')
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

---@param path string
---@param line? number
---@param col? number
function M.navigate_to_location(path, line, col)
  local resolved_path = resolve_path(path)
  if not resolved_path then
    return
  end
  local target_win = best_target_win()
  local windows = state.windows
  if config.ui.position == 'current' and windows and target_win == windows.output_win then
    require('opencode.ui.ui').hide_visible_windows(windows)
  end
  open_at(target_win, resolved_path, line, col)
end

function M.resolve_target_at_cursor()
  return M.resolve_file_at_cursor()
end

local function target_key(target)
  return table.concat({ target.path or '', target.line or 0, target.col or 0 }, ':')
end

local function symbol_targets_for_token(token)
  local reference_picker = require('opencode.ui.reference_picker')
  local symbol_snapshot = require('opencode.ui.symbol_snapshot')
  local refs = reference_picker.collect_refs()
  local snapshot = symbol_snapshot.collect(refs)
  local targets = {}
  local seen = {}

  for _, variant in ipairs(symbol_snapshot.token_variants(token)) do
    for _, target in ipairs(symbol_snapshot.targets_for_token(snapshot, variant)) do
      local key = target_key(target)
      if not seen[key] then
        seen[key] = true
        table.insert(targets, target)
      end
    end
  end

  return targets
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

local function pick_symbol_target(token, targets)
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

local function jump_to_symbol_at_cursor()
  local token = cursor_symbol_token()
  if not token then
    return
  end

  local targets = symbol_targets_for_token(token)
  if #targets == 0 then
    vim.notify('No symbol target found: ' .. token, vim.log.levels.INFO)
    return
  end

  if #targets == 1 then
    local target = targets[1]
    M.navigate_to_location(target.path, target.line, target.col)
    return
  end

  pick_symbol_target(token, targets)
end

function M.jump_to_target_at_cursor()
  local resolved = M.resolve_target_at_cursor()
  if resolved then
    M.navigate_to_location(resolved.path, resolved.line, resolved.col)
    return
  end

  jump_to_symbol_at_cursor()
end

function M.jump_to_file_at_cursor()
  local resolved = M.resolve_file_at_cursor()
  if not resolved then
    return
  end
  M.navigate_to_location(resolved.path, resolved.line, resolved.col)
end

return M
