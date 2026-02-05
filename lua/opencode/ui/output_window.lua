local state = require('opencode.state')
local config = require('opencode.config')

local M = {}
M.namespace = vim.api.nvim_create_namespace('opencode_output')
M.viewport_at_bottom = true

function M.create_buf()
  local output_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value('filetype', 'opencode_output', { buf = output_buf })

  local buffixwin = require('opencode.ui.buf_fix_win')
  buffixwin.fix_to_win(output_buf, function()
    local state = require('opencode.state')
    return state.windows and state.windows.output_win
  end)

  return output_buf
end

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

---Check if the output window is currently at the bottom
---@param win? integer Window ID, defaults to state.windows.output_win
---@return boolean true if at bottom, false otherwise
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

  local botline = vim.fn.line('w$', win)

  -- Consider at bottom if bottom visible line is at or near the end
  -- Use -1 tolerance for wrapped lines
  return botline >= line_count - 1
end

---Helper to set window option and save original value for position='current'
---@param opt_name string The option name
---@param value any The value to set
---@param win integer The window ID
local function set_win_option(opt_name, value, win)
  -- Save original value if using position = 'current'
  if config.ui.position == 'current' then
    if not state.saved_window_options then
      state.saved_window_options = {}
    end
    -- Only save if not already saved (in case this function is called multiple times)
    if state.saved_window_options[opt_name] == nil then
      local ok, original = pcall(vim.api.nvim_get_option_value, opt_name, { win = win })
      if ok then
        state.saved_window_options[opt_name] = original
      end
    end
  end

  vim.api.nvim_set_option_value(opt_name, value, { win = win, scope = 'local' })
end

---Helper to set buffer option (no saving needed)
---@param opt_name string The option name
---@param value any The value to set
---@param buf integer The buffer ID
local function set_buf_option(opt_name, value, buf)
  vim.api.nvim_set_option_value(opt_name, value, { buf = buf })
end

function M.setup(windows)
  set_win_option('winhighlight', config.ui.window_highlight, windows.output_win)
  set_win_option('wrap', true, windows.output_win)
  set_win_option('linebreak', true, windows.output_win)
  set_win_option('number', false, windows.output_win)
  set_win_option('relativenumber', false, windows.output_win)
  set_buf_option('modifiable', false, windows.output_buf)
  set_buf_option('buftype', 'nofile', windows.output_buf)
  set_buf_option('bufhidden', 'hide', windows.output_buf)
  set_buf_option('buflisted', false, windows.output_buf)
  set_buf_option('swapfile', false, windows.output_buf)

  if config.ui.position ~= 'current' then
    set_win_option('winfixbuf', true, windows.output_win)
  end
  set_win_option('winfixheight', true, windows.output_win)
  set_win_option('winfixwidth', true, windows.output_win)
  set_win_option('signcolumn', 'yes', windows.output_win)
  set_win_option('list', false, windows.output_win)
  set_win_option('statuscolumn', '', windows.output_win)

  M.update_dimensions(windows)
  M.setup_keymaps(windows)
end

function M.update_dimensions(windows)
  if config.ui.position == 'current' then
    return
  end
  local total_width = vim.api.nvim_get_option_value('columns', {})
  local width_ratio = state.pre_zoom_width and config.ui.zoom_width or config.ui.window_width
  local width = math.floor(total_width * width_ratio)

  vim.api.nvim_win_set_config(windows.output_win, { width = width })
end

function M.get_buf_line_count()
  if not M.mounted() then
    return 0
  end
  ---@cast state.windows { output_buf: integer }

  return vim.api.nvim_buf_line_count(state.windows.output_buf)
end

---Set the output buffer contents
---@param lines string[] The lines to set
---@param start_line? integer The starting line to set, defaults to 0
---@param end_line? integer The last line to set, defaults to -1
function M.set_lines(lines, start_line, end_line)
  if not M.mounted() then
    return
  end
  ---@cast state.windows { output_buf: integer }

  start_line = start_line or 0
  end_line = end_line or -1

  vim.api.nvim_set_option_value('modifiable', true, { buf = state.windows.output_buf })
  vim.api.nvim_buf_set_lines(state.windows.output_buf, start_line, end_line, false, lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = state.windows.output_buf })
end

---Clear output buf extmarks
---@param start_line? integer Line to start clearing, defaults 0
---@param end_line? integer Line to clear until, defaults to -1
---@param clear_all? boolean If true, clears all extmarks in the buffer
function M.clear_extmarks(start_line, end_line, clear_all)
  if not M.mounted() then
    return
  end
  ---@cast state.windows { output_buf: integer }

  start_line = start_line or 0
  end_line = end_line or -1

  vim.api.nvim_buf_clear_namespace(state.windows.output_buf, clear_all and -1 or M.namespace, start_line, end_line)
end

---Apply extmarks to the output buffer
---@param extmarks table<number, OutputExtmark[]> Extmarks indexed by line
---@param line_offset? integer Line offset to apply to extmarks, defaults to 0
function M.set_extmarks(extmarks, line_offset)
  if not M.mounted() or not extmarks or type(extmarks) ~= 'table' then
    return
  end
  ---@cast state.windows { output_buf: integer }

  line_offset = line_offset or 0

  local output_buf = state.windows.output_buf

  for line_idx, marks in pairs(extmarks) do
    for _, mark in ipairs(marks) do
      local actual_mark = type(mark) == 'function' and mark() or mark
      local target_line = line_offset + line_idx --[[@as integer]]
      if actual_mark.end_row then
        actual_mark.end_row = actual_mark.end_row + line_offset
      end
      local start_col = actual_mark.start_col
      if actual_mark.start_col then
        actual_mark.start_col = nil
      end
      ---@cast actual_mark vim.api.keyset.set_extmark
      pcall(vim.api.nvim_buf_set_extmark, output_buf, M.namespace, target_line, start_col or 0, actual_mark)
    end
  end
end

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

function M.close()
  if M.mounted() then
    return
  end
  ---@cast state.windows { output_win: integer, output_buf: integer }

  pcall(vim.api.nvim_win_close, state.windows.output_win, true)
  pcall(vim.api.nvim_buf_delete, state.windows.output_buf, { force = true })
end

function M.setup_keymaps(windows)
  local keymap = require('opencode.keymap')
  keymap.setup_window_keymaps(config.keymap.output_window, windows.output_buf)
end

function M.setup_autocmds(windows, group)
  vim.api.nvim_create_autocmd('WinEnter', {
    group = group,
    buffer = windows.output_buf,
    callback = function()
      local input_window = require('opencode.ui.input_window')
      state.last_focused_opencode_window = 'output'
      input_window.refresh_placeholder(state.windows)

      vim.cmd('stopinsert')
    end,
  })

  vim.api.nvim_create_autocmd('BufEnter', {
    group = group,
    buffer = windows.output_buf,
    callback = function()
      local input_window = require('opencode.ui.input_window')
      state.last_focused_opencode_window = 'output'
      input_window.refresh_placeholder(state.windows)

      vim.cmd('stopinsert')
    end,
  })

  -- Track scroll position when window is scrolled
  vim.api.nvim_create_autocmd('WinScrolled', {
    group = group,
    buffer = windows.output_buf,
    callback = function()
      M.viewport_at_bottom = M.is_at_bottom(windows.output_win)
    end,
  })
end

function M.clear()
  M.set_lines({})
  -- clear extmarks in all namespaces as I've seen RenderMarkdown leave some
  -- extmarks behind
  M.clear_extmarks(0, -1, true)
  M.viewport_at_bottom = true
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
