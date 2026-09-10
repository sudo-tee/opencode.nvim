local state = require('opencode.state')
local session_tabs = require('opencode.state.session_tabs')
local config = require('opencode.config')

local M = {}

local namespace = vim.api.nvim_create_namespace('opencode_session_tab_strip')
local ranges_by_buffer = {}
local subscribed = false
local minimum_tab_width = 12

local function prune_ranges()
  for buffer in pairs(ranges_by_buffer) do
    if not vim.api.nvim_buf_is_valid(buffer) then
      ranges_by_buffer[buffer] = nil
    end
  end
end

local function display_width(text)
  return vim.fn.strdisplaywidth(text)
end

---@param title string
---@return boolean
local function is_generated_title(title)
  local timestamp = title:match('^New session %- (.+)$')
  if not timestamp then
    return false
  end

  return timestamp:match('^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d%.%d+Z$') ~= nil
    or timestamp:match('^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$') ~= nil
end

---@param text string
---@param max_width integer
---@return string
local function truncate(text, max_width)
  if max_width <= 0 then
    return ''
  end
  if display_width(text) <= max_width then
    return text
  end
  if max_width <= 3 then
    return string.rep('.', max_width)
  end

  local target_width = max_width - 3
  for char_count = vim.fn.strchars(text), 0, -1 do
    local prefix = vim.fn.strcharpart(text, 0, char_count)
    if display_width(prefix) <= target_width then
      return prefix .. '...'
    end
  end
  return '...'
end

---@param tab OpencodeSessionTabRuntime
---@return string
local function tab_title(tab)
  local title = tab.active_session and tab.active_session.title
  if type(title) ~= 'string' or vim.trim(title) == '' then
    return 'New session'
  end
  if is_generated_title(title) then
    return 'New session'
  end
  return title
end

---@param tab OpencodeSessionTabRuntime
---@return string marker, string|nil highlight
local function pending_marker(tab)
  local permission_count = #(tab.pending_prompt_permissions or {})
  local question_count = #(tab.pending_questions or {})
  local marker_parts = {}

  if permission_count > 0 then
    marker_parts[#marker_parts + 1] = '[!' .. (permission_count > 1 and permission_count or '') .. ']'
  end
  if question_count > 0 then
    marker_parts[#marker_parts + 1] = '[?' .. (question_count > 1 and question_count or '') .. ']'
  end

  if #marker_parts == 0 then
    return '', nil
  end
  if permission_count > 0 then
    return table.concat(marker_parts), 'OpencodeSessionTabPendingPermission'
  end
  return table.concat(marker_parts), 'OpencodeSessionTabPendingQuestion'
end

---@param tabs OpencodeSessionTabRuntime[]
---@param width integer
---@return string line, table[] ranges, table[] highlights
local function build_horizontal_content(tabs, width)
  if #tabs == 0 then
    return '', {}, {}
  end

  local separator = ' │ '
  local separator_width = display_width(separator)
  local active_id = session_tabs.active_id()

  local function fit_layout(visible_count)
    local overflow_count = #tabs - visible_count
    local marker = overflow_count > 0 and ('+' .. overflow_count) or ''
    local separator_count = visible_count - 1 + (overflow_count > 0 and 1 or 0)
    local segment_width = math.max(
      minimum_tab_width,
      math.floor((width - separator_width * separator_count - display_width(marker)) / visible_count)
    )
    local total_width = segment_width * visible_count + separator_width * separator_count + display_width(marker)
    return segment_width, total_width, overflow_count, marker
  end

  local visible_count = #tabs
  local segment_width, total_width, overflow_count, marker = fit_layout(visible_count)
  if total_width > width then
    local layout_found = false
    for candidate = #tabs - 1, 1, -1 do
      local candidate_width, candidate_total, candidate_overflow, candidate_marker = fit_layout(candidate)
      if candidate_total <= width then
        visible_count = candidate
        segment_width = candidate_width
        total_width = candidate_total
        overflow_count = candidate_overflow
        marker = candidate_marker
        layout_found = true
        break
      end
    end
    if not layout_found then
      visible_count = 1
      segment_width, total_width, overflow_count, marker = fit_layout(visible_count)
    end
  end

  local active_index
  for index, tab in ipairs(tabs) do
    if tab.id == active_id then
      active_index = index
      break
    end
  end

  local visible_tabs = {}
  local first_count = visible_count
  if active_index and active_index > visible_count then
    first_count = visible_count - 1
  end
  for index = 1, first_count do
    visible_tabs[#visible_tabs + 1] = { index = index, tab = tabs[index] }
  end
  if active_index and active_index > visible_count then
    visible_tabs[#visible_tabs + 1] = { index = active_index, tab = tabs[active_index] }
  end

  local parts = {}
  local ranges = {}
  local highlights = {}
  local byte_col = 0
  local display_col = 0

  for visible_index, entry in ipairs(visible_tabs) do
    local index = entry.index
    local tab = entry.tab
    if visible_index > 1 then
      local separator_start = byte_col
      parts[#parts + 1] = separator
      byte_col = byte_col + #separator
      display_col = display_col + separator_width
      highlights[#highlights + 1] = {
        group = 'OpencodeSessionTabSeparator',
        start_col = separator_start,
        end_col = byte_col,
      }
    end

    local index_text = tostring(index)
    local prefix = index_text .. ' '
    local marker, marker_highlight = pending_marker(tab)
    local marker_prefix = marker ~= '' and marker .. ' ' or ''
    local title_width = segment_width - display_width(prefix) - display_width(marker_prefix)
    local label
    if title_width > 0 then
      label = prefix .. marker_prefix .. truncate(tab_title(tab), title_width)
    else
      label = prefix .. marker
      if display_width(label) > segment_width then
        label = truncate(label, segment_width)
      end
    end

    local start_byte = byte_col
    local start_display = display_col
    parts[#parts + 1] = label
    byte_col = byte_col + #label
    display_col = display_col + display_width(label)

    ranges[#ranges + 1] = {
      tab_id = tab.id,
      start_byte = start_byte,
      end_byte = byte_col,
      start_display = start_display,
      end_display = display_col,
    }
    highlights[#highlights + 1] = {
      group = tab.id == active_id and 'OpencodeSessionTabActive' or 'OpencodeSessionTabInactive',
      start_col = start_byte,
      end_col = byte_col,
    }
    if marker_highlight and marker ~= '' and label:find(marker, #prefix + 1, true) then
      highlights[#highlights + 1] = {
        group = marker_highlight,
        start_col = start_byte + #prefix,
        end_col = start_byte + #prefix + #marker,
        hl_mode = 'combine',
      }
    end
    highlights[#highlights + 1] = {
      group = 'OpencodeSessionTabIndex',
      start_col = start_byte,
      end_col = start_byte + #index_text,
      hl_mode = 'combine',
    }
  end

  if overflow_count > 0 then
    local separator_start = byte_col
    parts[#parts + 1] = separator
    byte_col = byte_col + #separator
    display_col = display_col + separator_width
    highlights[#highlights + 1] = {
      group = 'OpencodeSessionTabSeparator',
      start_col = separator_start,
      end_col = byte_col,
    }

    local marker_start = byte_col
    parts[#parts + 1] = marker
    byte_col = byte_col + #marker
    display_col = display_col + display_width(marker)
    ranges[#ranges + 1] = {
      open_picker = true,
      start_byte = marker_start,
      end_byte = byte_col,
      start_display = display_col - display_width(marker),
      end_display = display_col,
    }
    highlights[#highlights + 1] = {
      group = 'OpencodeSessionTabOverflow',
      start_col = marker_start,
      end_col = byte_col,
    }
  end

  return table.concat(parts), ranges, highlights
end

---@param windows OpencodeWindowState
---@return boolean
local function valid_output_windows(windows)
  return windows
    and windows.output_win
    and windows.tab_strip_buf
    and vim.api.nvim_win_is_valid(windows.output_win)
    and vim.api.nvim_buf_is_valid(windows.tab_strip_buf)
end

---@param windows OpencodeWindowState
---@return boolean
local function valid_windows(windows)
  return valid_output_windows(windows) and windows.tab_strip_win and vim.api.nvim_win_is_valid(windows.tab_strip_win)
end

---@param windows OpencodeWindowState
local function setup_window_options(windows)
  local win = windows.tab_strip_win
  local buf = windows.tab_strip_buf

  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = buf })
  vim.api.nvim_set_option_value('bufhidden', 'hide', { buf = buf })
  vim.api.nvim_set_option_value('buflisted', false, { buf = buf })
  vim.api.nvim_set_option_value('swapfile', false, { buf = buf })
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })

  vim.api.nvim_set_option_value('cursorline', false, { win = win })
  vim.api.nvim_set_option_value('number', false, { win = win })
  vim.api.nvim_set_option_value('relativenumber', false, { win = win })
  vim.api.nvim_set_option_value('signcolumn', 'no', { win = win })
  vim.api.nvim_set_option_value('statuscolumn', '', { win = win })
  vim.api.nvim_set_option_value('wrap', false, { win = win })
  vim.api.nvim_set_option_value('winbar', '', { win = win })
  vim.api.nvim_set_option_value(
    'winhighlight',
    'Normal:OpencodeBackground,EndOfBuffer:OpencodeBackground',
    { win = win }
  )

  if vim.api.nvim_win_get_config(win).relative == '' then
    vim.api.nvim_set_option_value('winfixheight', true, { win = win })
  end
end

---@param buffer integer
---@param display_column integer
---@return string|nil
local function range_at_display_column(buffer, display_column)
  for _, range in ipairs(ranges_by_buffer[buffer] or {}) do
    if display_column >= range.start_display and display_column < range.end_display then
      return range
    end
  end
  return nil
end

---@param buffer integer
---@param byte_column integer
---@return table|nil
local function range_at_byte_column(buffer, byte_column)
  for _, range in ipairs(ranges_by_buffer[buffer] or {}) do
    if byte_column >= range.start_byte and byte_column < range.end_byte then
      return range
    end
  end
  return nil
end

---@param tab_id string|nil
local function select_tab(tab_id)
  if not tab_id then
    return
  end
  require('opencode.services.session_runtime').switch_session_tab(tab_id)
end

---@param range table|nil
local function select_range(range)
  if not range then
    return
  end
  if range.open_picker then
    require('opencode.ui.session_tab_picker').select()
    return
  end
  select_tab(range.tab_id)
end

local function click_tab()
  local buffer = vim.api.nvim_get_current_buf()
  local mouse = vim.fn.getmousepos()
  select_range(range_at_display_column(buffer, math.max(0, mouse.column - 1)))
end

local function select_tab_under_cursor()
  local buffer = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  select_range(range_at_byte_column(buffer, cursor[2]))
end

---@param buffer integer
local function setup_keymaps(buffer)
  vim.keymap.set('n', '<LeftMouse>', click_tab, { buffer = buffer, silent = true, nowait = true })
  vim.keymap.set('n', '<2-LeftMouse>', click_tab, { buffer = buffer, silent = true, nowait = true })
  vim.keymap.set('n', '<CR>', select_tab_under_cursor, { buffer = buffer, silent = true, nowait = true })
end

---@param windows OpencodeWindowState
function M.render(windows)
  prune_ranges()
  windows = windows or state.windows
  if not valid_windows(windows) then
    return
  end

  local buffer = windows.tab_strip_buf
  local width = vim.api.nvim_win_get_width(windows.tab_strip_win)
  local tabs = session_tabs.list()
  local line, ranges, highlights = build_horizontal_content(tabs, math.max(1, width))

  vim.api.nvim_set_option_value('modifiable', true, { buf = buffer })
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { line })
  vim.api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)
  for _, highlight in ipairs(highlights) do
    vim.api.nvim_buf_set_extmark(buffer, namespace, 0, highlight.start_col, {
      end_col = highlight.end_col,
      hl_group = highlight.group,
      hl_mode = highlight.hl_mode,
    })
  end
  vim.api.nvim_set_option_value('modifiable', false, { buf = buffer })

  ranges_by_buffer[buffer] = ranges
end

---@param output_win integer
---@return vim.api.keyset.win_config
local function build_float_config(output_win)
  return {
    relative = 'win',
    win = output_win,
    anchor = 'NW',
    width = vim.api.nvim_win_get_width(output_win),
    height = 1,
    row = 0,
    col = 0,
    focusable = true,
    style = 'minimal',
    border = 'none',
    zindex = 50,
  }
end

---@param windows OpencodeWindowState
---@return integer|nil
function M.create_window(windows)
  if not windows.output_win or not windows.tab_strip_buf or not vim.api.nvim_win_is_valid(windows.output_win) then
    return nil
  end
  if config.ui.hide_single_tab and #session_tabs.list() == 1 then
    return nil
  end
  if windows.tab_strip_win and vim.api.nvim_win_is_valid(windows.tab_strip_win) then
    return windows.tab_strip_win
  end

  local output_config = vim.api.nvim_win_get_config(windows.output_win)
  if output_config.relative == '' then
    windows.tab_strip_win = vim.api.nvim_open_win(windows.tab_strip_buf, false, {
      split = 'above',
      win = windows.output_win,
    })
    vim.api.nvim_win_set_height(windows.tab_strip_win, 1)
  else
    windows.tab_strip_win = vim.api.nvim_open_win(windows.tab_strip_buf, false, build_float_config(windows.output_win))
  end

  setup_window_options(windows)
  setup_keymaps(windows.tab_strip_buf)
  return windows.tab_strip_win
end

---@param buffer integer
function M.clear_buffer(buffer)
  ranges_by_buffer[buffer] = nil
end

---@param windows OpencodeWindowState
local function close_window(windows)
  if windows.tab_strip_win and vim.api.nvim_win_is_valid(windows.tab_strip_win) then
    pcall(vim.api.nvim_win_close, windows.tab_strip_win, true)
  end
  windows.tab_strip_win = nil
  if windows.tab_strip_buf then
    M.clear_buffer(windows.tab_strip_buf)
  end
end

---@param windows? OpencodeWindowState
---@return boolean
function M.mounted(windows)
  return valid_windows(windows or state.windows)
end

---@param windows? OpencodeWindowState
function M.update_window(windows)
  windows = windows or state.windows
  if not valid_output_windows(windows) then
    return
  end

  local tabs = session_tabs.list()
  if config.ui.hide_single_tab and #tabs == 1 then
    close_window(windows)
    return
  end

  if not windows.tab_strip_win or not vim.api.nvim_win_is_valid(windows.tab_strip_win) then
    if not M.create_window(windows) then
      return
    end
  end

  if vim.api.nvim_win_get_config(windows.tab_strip_win).relative ~= '' then
    pcall(vim.api.nvim_win_set_config, windows.tab_strip_win, build_float_config(windows.output_win))
  end
  M.render(windows)
end

---@return integer
function M.create_buf()
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value('filetype', 'opencode_session_tabs', { buf = buffer })
  return buffer
end

local function on_change()
  M.update_window()
end

---@param windows OpencodeWindowState
function M.setup(windows)
  if not valid_output_windows(windows) then
    return false
  end

  if not subscribed then
    state.store.subscribe('active_session', on_change)
    state.store.subscribe('active_session_tab', on_change)
    state.store.subscribe('session_tabs_changed', on_change)
    subscribed = true
  end

  M.update_window(windows)
  return true
end

---@param preserve_buffer? boolean
---@param windows? OpencodeWindowState
function M.close(preserve_buffer, windows)
  windows = windows or state.windows
  if windows then
    close_window(windows)
    if not preserve_buffer and windows.tab_strip_buf and vim.api.nvim_buf_is_valid(windows.tab_strip_buf) then
      pcall(vim.api.nvim_buf_delete, windows.tab_strip_buf, { force = true })
    end
  end

  if subscribed then
    state.store.unsubscribe('active_session', on_change)
    state.store.unsubscribe('active_session_tab', on_change)
    state.store.unsubscribe('session_tabs_changed', on_change)
    subscribed = false
  end
end

return M
