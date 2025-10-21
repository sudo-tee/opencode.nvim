local state = require('opencode.state')
local config = require('opencode.config')

local M = {}
M.namespace = vim.api.nvim_create_namespace('opencode_output')

function M.create_buf()
  local output_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value('filetype', 'opencode_output', { buf = output_buf })
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

function M.mounted(windows)
  windows = windows or state.windows
  if
    not state.windows
    or not state.windows.output_buf
    or not state.windows.output_win
    or not vim.api.nvim_win_is_valid(windows.output_win)
  then
    return false
  end

  return true
end

function M.setup(windows)
  vim.api.nvim_set_option_value('winhighlight', config.ui.window_highlight, { win = windows.output_win })
  vim.api.nvim_set_option_value('wrap', true, { win = windows.output_win })
  vim.api.nvim_set_option_value('number', false, { win = windows.output_win })
  vim.api.nvim_set_option_value('relativenumber', false, { win = windows.output_win })
  vim.api.nvim_set_option_value('modifiable', false, { buf = windows.output_buf })
  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = windows.output_buf })
  vim.api.nvim_set_option_value('swapfile', false, { buf = windows.output_buf })
  vim.api.nvim_set_option_value('winfixbuf', true, { win = windows.output_win })
  vim.api.nvim_set_option_value('winfixheight', true, { win = windows.output_win })
  vim.api.nvim_set_option_value('winfixwidth', true, { win = windows.output_win })
  vim.api.nvim_set_option_value('signcolumn', 'yes', { scope = 'local', win = windows.output_win })

  M.update_dimensions(windows)
  M.setup_keymaps(windows)
end

function M.update_dimensions(windows)
  local total_width = vim.api.nvim_get_option_value('columns', {})
  local width = math.floor(total_width * config.ui.window_width)

  vim.api.nvim_win_set_config(windows.output_win, { width = width })
end

function M.get_buf_line_count()
  if not M.mounted() then
    return 0
  end

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

  start_line = start_line or 0
  end_line = end_line or -1

  local windows = state.windows
  if not windows or not windows.output_buf then
    return
  end

  vim.api.nvim_set_option_value('modifiable', true, { buf = windows.output_buf })
  vim.api.nvim_buf_set_lines(windows.output_buf, start_line, end_line, false, lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = windows.output_buf })
end

---Clear output buf extmarks
---@param start_line? integer Line to start clearing, defaults 0
---@param end_line? integer Line to to clear until, defaults to -1
function M.clear_extmarks(start_line, end_line)
  if not M.mounted() or not state.windows.output_buf then
    return
  end

  start_line = start_line or 0
  end_line = end_line or -1

  vim.api.nvim_buf_clear_namespace(state.windows.output_buf, M.namespace, start_line, end_line)
end

---Apply extmarks to the output buffer
---@param extmarks table<number, OutputExtmark> Extmarks indexed by line
---@param line_offset? integer Line offset to apply to extmarks, defaults to 0
function M.set_extmarks(extmarks, line_offset)
  if not M.mounted() or not extmarks or type(extmarks) ~= 'table' then
    return
  end

  line_offset = line_offset or 0

  local output_buf = state.windows.output_buf

  for line_idx, marks in pairs(extmarks) do
    for _, mark in ipairs(marks) do
      local actual_mark = type(mark) == 'function' and mark() or mark
      local target_line = line_offset + line_idx - 1
      if actual_mark.end_row then
        actual_mark.end_row = actual_mark.end_row + line_offset
      end
      local start_col = actual_mark.start_col
      if actual_mark.start_col then
        actual_mark.start_col = nil
      end
      pcall(vim.api.nvim_buf_set_extmark, output_buf, M.namespace, target_line, start_col or 0, actual_mark)
    end
  end
end

function M.focus_output(should_stop_insert)
  if should_stop_insert then
    vim.cmd('stopinsert')
  end
  vim.api.nvim_set_current_win(state.windows.output_win)
end

function M.close()
  if M.mounted() then
    return
  end
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
      vim.cmd('stopinsert')
      state.last_focused_opencode_window = 'output'
      require('opencode.ui.input_window').refresh_placeholder(state.windows)
    end,
  })

  vim.api.nvim_create_autocmd('BufEnter', {
    group = group,
    buffer = windows.output_buf,
    callback = function()
      vim.cmd('stopinsert')
      state.last_focused_opencode_window = 'output'
      require('opencode.ui.input_window').refresh_placeholder(state.windows)
    end,
  })
end

function M.clear()
  M.set_lines({})
  M.clear_extmarks()
end

return M
