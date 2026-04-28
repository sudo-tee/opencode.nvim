local state = require('opencode.state')
local config = require('opencode.config')
local window_options = require('opencode.ui.window_options')

local M = {}
M.namespace = vim.api.nvim_create_namespace('opencode_output')
M.debug_namespace = vim.api.nvim_create_namespace('opencode_output_debug')
M.markdown_namespace = vim.api.nvim_create_namespace('opencode_output_markdown')
M._last_visible_bottom_by_win = {}
M._was_at_bottom_by_win = {}
M._prev_line_count_by_win = {}

local _update_depth = 0
local _update_buf = nil

---Begin a batch of buffer writes — toggle modifiable once for the whole batch.
---Returns true if the batch was opened (buffer is valid). Must be paired with end_update().
---@return boolean
function M.begin_update()
  local windows = state.windows
  if not windows or not windows.output_buf then
    return false
  end
  if _update_depth == 0 then
    _update_buf = windows.output_buf
    vim.api.nvim_set_option_value('modifiable', true, { buf = _update_buf })
  end
  _update_depth = _update_depth + 1
  return true
end

---End a batch started by begin_update().
function M.end_update()
  if _update_depth == 0 then
    return
  end
  _update_depth = _update_depth - 1
  if _update_depth == 0 and _update_buf then
    pcall(vim.api.nvim_set_option_value, 'modifiable', false, { buf = _update_buf })
    _update_buf = nil
  end
end

---@return integer
function M.create_buf()
  local output_buf = vim.api.nvim_create_buf(false, true)
  local filetype = config.ui.output.filetype or 'opencode_output'
  vim.api.nvim_set_option_value('filetype', filetype, { buf = output_buf })

  vim.api.nvim_buf_set_var(output_buf, 'opencode_folds', {})

  local buffixwin = require('opencode.ui.buf_fix_win')
  buffixwin.fix_to_win(output_buf, function()
    return state.windows and state.windows.output_win
  end)

  return output_buf
end

---@return vim.api.keyset.win_config
function M._build_output_win_config()
  return {
    relative = 'editor',
    width = config.ui.window_width or 80,
    row = 2,
    col = 2,
    style = 'minimal',
    border = 'rounded',
    zindex = 40,
  }
end

---@param windows OpencodeWindowState?
function M.mounted(windows)
  windows = windows or state.windows
  return windows and windows.output_buf and windows.output_win and vim.api.nvim_win_is_valid(windows.output_win)
end

---Check if the output buffer is valid (even if window is hidden)
---@param windows? OpencodeWindowState
---@return boolean
function M.buffer_valid(windows)
  windows = windows or state.windows
  return windows and windows.output_buf and vim.api.nvim_buf_is_valid(windows.output_buf)
end

---Check if the cursor in the output window is at (or was at) the bottom of
---the buffer, using the same logic as the original implementation.
---Returns true if the window should continue auto-scrolling.
---@param win? integer Window ID, defaults to state.windows.output_win
---@return boolean
function M.is_at_bottom(win)
  if config.ui.output.always_scroll_to_bottom then
    return true
  end

  win = win or (state.windows and state.windows.output_win)

  if not win or not vim.api.nvim_win_is_valid(win) then
    return true
  end

  if not state.windows or not state.windows.output_buf then
    return true
  end

  local ok, line_count = pcall(vim.api.nvim_buf_line_count, state.windows.output_buf)
  if not ok or not line_count or line_count == 0 then
    return true
  end

  local ok2, cursor = pcall(vim.api.nvim_win_get_cursor, win)
  if not ok2 then
    return true
  end

  local prev_line_count = M._prev_line_count_by_win[win] or line_count
  return cursor[1] >= prev_line_count or cursor[1] >= line_count
end

---@param win? integer
---@return integer|nil
function M.get_visible_bottom_line(win)
  win = win or (state.windows and state.windows.output_win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  local ok, line = pcall(vim.fn.line, 'w$', win)
  return (ok and line and line > 0) and line or nil
end

---@param win? integer
function M.reset_scroll_tracking(win)
  if win then
    M._last_visible_bottom_by_win[win] = nil
    M._was_at_bottom_by_win[win] = nil
    M._prev_line_count_by_win[win] = nil
    return
  end

  M._last_visible_bottom_by_win = {}
  M._was_at_bottom_by_win = {}
  M._prev_line_count_by_win = {}
end

---@param win? integer
function M.sync_cursor_with_viewport(win)
  win = win or (state.windows and state.windows.output_win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end

  local windows = state.windows
  local buf = windows and windows.output_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_win_get_buf(win) ~= buf then
    M.reset_scroll_tracking(win)
    return
  end

  local ok, line_count = pcall(vim.api.nvim_buf_line_count, buf)
  local visible_bottom = M.get_visible_bottom_line(win)
  if not ok or not line_count or line_count == 0 or not visible_bottom then
    return
  end

  M._last_visible_bottom_by_win[win] = visible_bottom
end

---@param windows OpencodeWindowState
function M.setup(windows)
  window_options.set_window_option(
    'winhighlight',
    config.ui.window_highlight,
    windows.output_win,
    { save_original = true }
  )
  window_options.set_window_option('wrap', true, windows.output_win, { save_original = true })
  window_options.set_window_option('linebreak', true, windows.output_win, { save_original = true })
  window_options.set_window_option('cursorline', false, windows.output_win, { save_original = true })
  window_options.set_window_option('number', false, windows.output_win, { save_original = true })
  window_options.set_window_option('relativenumber', false, windows.output_win, { save_original = true })
  window_options.set_buffer_option('modifiable', false, windows.output_buf)
  window_options.set_buffer_option('buftype', 'nofile', windows.output_buf)
  window_options.set_buffer_option('bufhidden', 'hide', windows.output_buf)
  window_options.set_buffer_option('buflisted', false, windows.output_buf)
  window_options.set_buffer_option('swapfile', false, windows.output_buf)
  window_options.set_buffer_option('undofile', false, windows.output_buf)
  window_options.set_buffer_option('undolevels', -1, windows.output_buf)
  window_options.set_window_option('foldmethod', 'expr', windows.output_win)
  window_options.set_window_option('foldexpr', 'v:lua.opencode_fold_expr()', windows.output_win)
  window_options.set_window_option('foldenable', true, windows.output_win)
  window_options.set_window_option('foldlevel', 0, windows.output_win)
  window_options.set_window_option('foldcolumn', '1', windows.output_win)
  window_options.set_window_option('foldtext', 'v:lua.opencode_fold_text()', windows.output_win)

  if config.ui.position ~= 'current' then
    window_options.set_window_option('winfixbuf', true, windows.output_win, { save_original = true })
  end
  window_options.set_window_option('winfixheight', true, windows.output_win, { save_original = true })
  window_options.set_window_option('winfixwidth', true, windows.output_win, { save_original = true })
  window_options.set_window_option('signcolumn', 'yes', windows.output_win, { save_original = true })
  window_options.set_window_option('list', false, windows.output_win, { save_original = true })
  window_options.set_window_option('statuscolumn', '', windows.output_win, { save_original = true })
  window_options.set_window_option('colorcolumn', '', windows.output_win, { save_original = true })

  M.update_dimensions(windows)
  M.reset_scroll_tracking(windows.output_win)
  M._last_visible_bottom_by_win[windows.output_win] = M.get_visible_bottom_line(windows.output_win)
  M.setup_keymaps(windows)
end

---@param windows OpencodeWindowState?
function M.update_dimensions(windows)
  if config.ui.position == 'current' then
    return
  end

  if not windows or not windows.output_win or not vim.api.nvim_win_is_valid(windows.output_win) then
    return
  end

  local total_width = vim.api.nvim_get_option_value('columns', {})

  local width_ratio
  if windows.saved_width_ratio then
    width_ratio = windows.saved_width_ratio
    windows.saved_width_ratio = nil
  elseif state.pre_zoom_width then
    width_ratio = config.ui.zoom_width
  else
    width_ratio = config.ui.window_width
  end

  local width = math.floor(total_width * width_ratio)
  local ok, win_config = pcall(vim.api.nvim_win_get_config, windows.output_win)
  if not ok then
    return
  end

  if win_config.relative == '' then
    pcall(vim.api.nvim_win_set_width, windows.output_win, width)
    return
  end

  pcall(vim.api.nvim_win_set_config, windows.output_win, { width = width })
end

---Fold expression for the output buffer
---@return number
function M.fold_expr()
  local output_buf = nil

  local windows = state.windows
  if windows and windows.output_buf and vim.api.nvim_buf_is_valid(windows.output_buf) then
    output_buf = windows.output_buf
  else
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_has_var(buf, 'opencode_folds') then
        output_buf = buf
        break
      end
    end
  end

  if not output_buf then
    return 0
  end

  local line = vim.v.lnum
  local ok, folds = pcall(function()
    return vim.api.nvim_buf_get_var(output_buf, 'opencode_folds')
  end)
  if not ok or not folds then
    return 0
  end

  for _, range in ipairs(folds) do
    if line >= range.from and line <= range.to then
      return 1
    end
  end
  return 0
end

---Fold text for the output buffer
---@return string
function M.fold_text()
  local windows = state.windows
  local output_buf = windows and windows.output_buf
  local line = vim.v.foldstart

  if not output_buf or not vim.api.nvim_buf_is_valid(output_buf) then
    return vim.fn.foldtext()
  end

  local ok, folds = pcall(function()
    return vim.api.nvim_buf_get_var(output_buf, 'opencode_folds')
  end)
  if not ok or not folds then
    return vim.fn.foldtext()
  end

  local line_count = 0
  for _, range in ipairs(folds) do
    if line >= range.from and line <= range.to then
      line_count = range.to - range.from + 1
      break
    end
  end

  if line_count > 0 then
    local text = string.format('▶ %d lines hidden (zo open, zc close) ◀', line_count)
    local width = vim.api.nvim_win_get_width(0)
    local padding = math.max(0, math.floor((width - #text) / 2))
    return string.rep('-', padding) .. text .. string.rep('-', padding)
  end
  return vim.fn.foldtext()
end

_G.opencode_fold_expr = M.fold_expr
_G.opencode_fold_text = M.fold_text

---Set the folds for the output buffer
---@param fold_ranges table<{from: number, to: number}>
function M.set_folds(fold_ranges)
  local windows = state.windows
  if not windows or not windows.output_buf or not vim.api.nvim_buf_is_valid(windows.output_buf) then
    return
  end

  local folds = fold_ranges or {}
  local buf = windows.output_buf
  local win = windows.output_win

  local ok, prev_folds = pcall(vim.api.nvim_buf_get_var, buf, 'opencode_folds')
  if ok and vim.deep_equal(prev_folds, folds) then
    return
  end

  vim.api.nvim_buf_set_var(buf, 'opencode_folds', folds)

  if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
    pcall(vim.api.nvim_win_call, win, function()
      vim.cmd('silent! normal! zX')
    end)
  end
end

---Shift fold ranges
---@param start_line integer
---@param delta integer
function M.shift_folds(start_line, delta)
  local windows = state.windows
  if not windows or not windows.output_buf then
    return
  end
  local buf = windows.output_buf
  local ok, folds = pcall(vim.api.nvim_buf_get_var, buf, 'opencode_folds')
  if not ok or not folds then
    return
  end

  for _, range in ipairs(folds) do
    if range.from >= start_line then
      range.from = range.from + delta
      if delta < 0 then
        range.from = math.max(start_line, range.from)
      end
    end
    if range.to >= start_line then
      range.to = range.to + delta
      if delta < 0 then
        range.to = math.max(start_line, range.to)
      end
    end
    if range.to < range.from then
      range.to = range.from
    end
  end
end

---@return integer
function M.get_buf_line_count()
  local windows = state.windows
  if not windows or not windows.output_buf or not vim.api.nvim_buf_is_valid(windows.output_buf) then
    return 0
  end
  return vim.api.nvim_buf_line_count(windows.output_buf)
end

---Set the output buffer contents
---@param lines string[] The lines to set
---@param start_line? integer The starting line to set, defaults to 0
---@param end_line? integer The last line to set, defaults to -1
function M.set_lines(lines, start_line, end_line)
  local windows = state.windows
  if not windows or not windows.output_buf or not vim.api.nvim_buf_is_valid(windows.output_buf) then
    return
  end

  local buf = windows.output_buf
  start_line = start_line or 0
  end_line = end_line or -1

  -- Skip identical content outside of batch mode to avoid unnecessary writes
  -- that cause flicker (e.g. when a markdown plugin re-renders an unchanged part).
  -- Inside begin_update/end_update the caller controls exactly what is written,
  -- so the check would be redundant and expensive.
  if _update_depth == 0 then
    local ok, existing = pcall(vim.api.nvim_buf_get_lines, buf, start_line, end_line, false)
    if ok and existing and #existing == #lines then
      local same = true
      for i = 1, #lines do
        if existing[i] ~= lines[i] then
          same = false
          break
        end
      end
      if same then
        return
      end
    end
  end

  if _update_depth == 0 then
    vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, start_line, end_line, false, lines)
    vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
  else
    vim.api.nvim_buf_set_lines(buf, start_line, end_line, false, lines)
  end
end

---Clear output buf extmarks
---@param start_line? integer Line to start clearing, defaults 0
---@param end_line? integer Line to clear until, defaults to -1
---@param clear_all? boolean If true, clears all extmarks in the buffer
function M.clear_extmarks(start_line, end_line, clear_all)
  local windows = state.windows
  if not windows or not windows.output_buf or not vim.api.nvim_buf_is_valid(windows.output_buf) then
    return
  end

  start_line = start_line or 0
  end_line = end_line or -1

  pcall(vim.api.nvim_buf_clear_namespace, windows.output_buf, clear_all and -1 or M.namespace, start_line, end_line)
end

---Apply extmarks to the output buffer
---@param extmarks table<number, OutputExtmark[]> Extmarks indexed by line
---@param line_offset? integer Line offset to apply to extmarks, defaults to 0
function M.set_extmarks(extmarks, line_offset)
  if not extmarks or type(extmarks) ~= 'table' then
    return
  end
  local windows = state.windows
  if not windows or not windows.output_buf or not vim.api.nvim_buf_is_valid(windows.output_buf) then
    return
  end

  line_offset = line_offset or 0

  local output_buf = windows.output_buf

  local line_indices = vim.tbl_keys(extmarks)
  table.sort(line_indices)

  for _, line_idx in ipairs(line_indices) do
    local marks = extmarks[line_idx]
    table.sort(marks, function(a, b)
      local ma = type(a) == 'function' and a() or a
      local mb = type(b) == 'function' and b() or b
      return (ma.priority or 0) > (mb.priority or 0)
    end)

    for _, mark in ipairs(marks) do
      local m = type(mark) == 'function' and mark() or mark
      local target_line = line_offset + line_idx --[[@as integer]]
      local start_col = m.start_col
      -- Only deepcopy when we need to mutate: start_col must be removed from the
      -- opts table, and end_row must be offset when line_offset is non-zero.
      -- The vast majority of extmarks (border virt_text) have neither field, so
      -- we avoid 100k+ deepcopy calls during a full session render.
      if start_col ~= nil or (m.end_row ~= nil and line_offset ~= 0) then
        m = vim.deepcopy(m)
        m.start_col = nil
        if m.end_row then
          m.end_row = m.end_row + line_offset
        end
      end
      ---@cast m vim.api.keyset.set_extmark
      pcall(vim.api.nvim_buf_set_extmark, output_buf, M.namespace, target_line, start_col or 0, m)
    end
  end
end

---@param start_line integer
---@param end_line integer
function M.highlight_changed_lines(start_line, end_line)
  local windows = state.windows
  if not windows or not windows.output_buf or not vim.api.nvim_buf_is_valid(windows.output_buf) then
    return
  end
  if not config.debug.highlight_changed_lines then
    return
  end

  local buf = windows.output_buf
  local first = math.max(0, start_line)
  if end_line < start_line then
    return
  end
  local last = math.max(first, end_line)

  vim.api.nvim_buf_clear_namespace(buf, M.debug_namespace, first, last + 1)
  for line = first, last do
    vim.api.nvim_buf_set_extmark(buf, M.debug_namespace, line, 0, {
      line_hl_group = 'OpencodeChangedLines',
      hl_eol = true,
      priority = 250,
    })
  end

  vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, M.debug_namespace, first, last + 1)
    end
  end, config.debug.highlight_changed_lines_timeout_ms or 120)
end

---@param should_stop_insert? boolean
function M.focus_output(should_stop_insert)
  if not M.mounted() then
    return
  end
  ---@cast state.windows { output_win: integer }

  if should_stop_insert then
    vim.cmd('stopinsert')
  end
  vim.api.nvim_set_current_win(state.windows.output_win)
end

---Close and delete the output window and buffer.
function M.close()
  if not M.mounted() then
    return
  end
  ---@cast state.windows { output_win: integer, output_buf: integer }

  M.reset_scroll_tracking(state.windows.output_win)
  pcall(vim.api.nvim_win_close, state.windows.output_win, true)
  pcall(vim.api.nvim_buf_delete, state.windows.output_buf, { force = true })
end

---@param windows OpencodeWindowState
function M.setup_keymaps(windows)
  local keymap = require('opencode.keymap')
  keymap.setup_window_keymaps(config.keymap.output_window, windows.output_buf)
end

---@param windows OpencodeWindowState
---@param group integer
function M.setup_autocmds(windows, group)
  vim.api.nvim_create_autocmd('WinEnter', {
    group = group,
    buffer = windows.output_buf,
    callback = function()
      local input_window = require('opencode.ui.input_window')
      state.ui.set_last_focused_window('output')
      input_window.refresh_placeholder(state.windows)

      vim.cmd('stopinsert')
    end,
  })

  vim.api.nvim_create_autocmd('BufEnter', {
    group = group,
    buffer = windows.output_buf,
    callback = function()
      local input_window = require('opencode.ui.input_window')
      state.ui.set_last_focused_window('output')
      input_window.refresh_placeholder(state.windows)

      vim.cmd('stopinsert')
    end,
  })

  vim.api.nvim_create_autocmd('CursorMoved', {
    group = group,
    buffer = windows.output_buf,
    callback = function()
      local pos = state.ui.get_window_cursor(windows.output_win)
      if pos then
        state.ui.set_cursor_position('output', pos)
      end
    end,
  })

  vim.api.nvim_create_autocmd('WinScrolled', {
    group = group,
    buffer = windows.output_buf,
    callback = function()
      M.sync_cursor_with_viewport(windows.output_win)
    end,
  })
end

---Clear the output buffer and all namespaces.
function M.clear()
  M.set_lines({})
  -- clear extmarks in all namespaces as I've seen RenderMarkdown leave some
  -- extmarks behind
  M.clear_extmarks(0, -1, true)
end

---Get the output buffer
---@return integer|nil Buffer ID
function M.get_buf()
  return state.windows and state.windows.output_buf
end

---Trigger a re-render by calling the renderer
function M.render()
  local renderer = require('opencode.ui.renderer')
  renderer._render_all_messages()
end

return M
