local state = require('opencode.state')
local session_tabs = require('opencode.state.session_tabs')

local M = {}

local namespace = vim.api.nvim_create_namespace('opencode_session_tab_strip')
local ranges_by_buffer = {}
local subscribed = false

local function display_width(text)
  return vim.fn.strdisplaywidth(text)
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
  return title
end

---@param tabs OpencodeSessionTabRuntime[]
---@param width integer
---@return string line, table[] ranges, table[] highlights
local function build_horizontal_content(tabs, width)
  if #tabs == 0 then
    return '', {}, {}
  end

  local separator = ' '
  local separator_width = display_width(separator)
  local segment_width = math.max(3, math.floor((width - separator_width * math.max(0, #tabs - 1)) / #tabs))
  local active_id = session_tabs.active_id()
  local parts = {}
  local ranges = {}
  local highlights = {}
  local byte_col = 0
  local display_col = 0

  for index, tab in ipairs(tabs) do
    if index > 1 then
      parts[#parts + 1] = separator
      byte_col = byte_col + #separator
      display_col = display_col + separator_width
    end

    local marker = tab.id == active_id and '> ' or '  '
    local prefix = marker .. '[' .. index .. ' '
    local suffix = ']'
    local title_width = segment_width - display_width(prefix) - display_width(suffix)
    local label
    if title_width > 0 then
      label = prefix .. truncate(tab_title(tab), title_width) .. suffix
    else
      label = marker .. '[' .. index .. ']'
      if display_width(label) > segment_width then
        label = truncate(tostring(index), segment_width)
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
  end

  return table.concat(parts), ranges, highlights
end

---@param windows OpencodeWindowState
---@return boolean
local function valid_windows(windows)
  return windows
    and windows.output_win
    and windows.tab_strip_win
    and windows.tab_strip_buf
    and vim.api.nvim_win_is_valid(windows.output_win)
    and vim.api.nvim_win_is_valid(windows.tab_strip_win)
    and vim.api.nvim_buf_is_valid(windows.tab_strip_buf)
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
local function tab_id_at_display_column(buffer, display_column)
  for _, range in ipairs(ranges_by_buffer[buffer] or {}) do
    if display_column >= range.start_display and display_column < range.end_display then
      return range.tab_id
    end
  end
  return nil
end

---@param buffer integer
---@param byte_column integer
---@return string|nil
local function tab_id_at_byte_column(buffer, byte_column)
  for _, range in ipairs(ranges_by_buffer[buffer] or {}) do
    if byte_column >= range.start_byte and byte_column < range.end_byte then
      return range.tab_id
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

local function click_tab()
  local buffer = vim.api.nvim_get_current_buf()
  local mouse = vim.fn.getmousepos()
  select_tab(tab_id_at_display_column(buffer, math.max(0, mouse.column - 1)))
end

local function select_tab_under_cursor()
  local buffer = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  select_tab(tab_id_at_byte_column(buffer, cursor[2]))
end

---@param buffer integer
local function setup_keymaps(buffer)
  vim.keymap.set('n', '<LeftMouse>', click_tab, { buffer = buffer, silent = true, nowait = true })
  vim.keymap.set('n', '<2-LeftMouse>', click_tab, { buffer = buffer, silent = true, nowait = true })
  vim.keymap.set('n', '<CR>', select_tab_under_cursor, { buffer = buffer, silent = true, nowait = true })
end

---@param windows OpencodeWindowState
function M.render(windows)
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
    mouse = true,
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

---@param windows? OpencodeWindowState
---@return boolean
function M.mounted(windows)
  return valid_windows(windows or state.windows)
end

---@param windows? OpencodeWindowState
function M.update_window(windows)
  windows = windows or state.windows
  if not valid_windows(windows) then
    return
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
  M.render()
end

---@param windows OpencodeWindowState
function M.setup(windows)
  if not valid_windows(windows) then
    return false
  end

  if not subscribed then
    state.store.subscribe('active_session', on_change)
    state.store.subscribe('active_session_tab', on_change)
    subscribed = true
  end

  setup_window_options(windows)
  setup_keymaps(windows.tab_strip_buf)
  M.render(windows)
  return true
end

---@param preserve_buffer? boolean
---@param windows? OpencodeWindowState
function M.close(preserve_buffer, windows)
  windows = windows or state.windows
  if windows then
    if windows.tab_strip_win and vim.api.nvim_win_is_valid(windows.tab_strip_win) then
      pcall(vim.api.nvim_win_close, windows.tab_strip_win, true)
    end
    if not preserve_buffer and windows.tab_strip_buf and vim.api.nvim_buf_is_valid(windows.tab_strip_buf) then
      pcall(vim.api.nvim_buf_delete, windows.tab_strip_buf, { force = true })
    end
    if windows.tab_strip_buf then
      ranges_by_buffer[windows.tab_strip_buf] = nil
    end
  end

  if subscribed then
    state.store.unsubscribe('active_session', on_change)
    state.store.unsubscribe('active_session_tab', on_change)
    subscribed = false
  end
end

return M
