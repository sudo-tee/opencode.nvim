local state = require('opencode.state')
local config = require('opencode.config')

local PAD_LINES = 2

local M = {}

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

function M.create_window(windows)
  windows.output_win = vim.api.nvim_open_win(windows.output_buf, true, M._build_output_win_config())
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

  M.update_dimensions(windows)
  M.setup_keymaps(windows)
  state.subscribe('restore_points', function(_, new_val, old_val)
    local outout_renderer = require('opencode.ui.output_renderer')
    outout_renderer.render(state.windows, true)
  end)
end

function M.update_dimensions(windows)
  local total_width = vim.api.nvim_get_option_value('columns', {})
  local width = math.floor(total_width * config.ui.window_width)

  vim.api.nvim_win_set_config(windows.output_win, { width = width })
end

function M.set_content(lines)
  if not M.mounted() then
    return
  end

  local windows = state.windows
  if not windows or not windows.output_buf then
    return
  end
  vim.api.nvim_set_option_value('modifiable', true, { buf = windows.output_buf })
  local padded = vim.tbl_extend('force', {}, lines)
  for _ = 1, PAD_LINES do
    table.insert(padded, '')
  end
  vim.api.nvim_buf_set_lines(windows.output_buf, 0, -1, false, padded)
  vim.api.nvim_set_option_value('modifiable', false, { buf = windows.output_buf })
end

function M.append_content(lines, offset)
  if not M.mounted() then
    return
  end

  local windows = state.windows
  if not windows or not windows.output_buf then
    return
  end

  local cur_count = vim.api.nvim_buf_line_count(windows.output_buf)

  vim.api.nvim_set_option_value('modifiable', true, { buf = windows.output_buf })
  vim.api.nvim_buf_set_lines(windows.output_buf, cur_count - PAD_LINES, cur_count - PAD_LINES, false, lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = windows.output_buf })
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

  state.subscribe('current_permission', function()
    require('opencode.keymap').toggle_permission_keymap(windows.output_buf)
  end)
end

function M.clear()
  if not M.mounted() then
    return
  end
  vim.api.nvim_buf_clear_namespace(state.windows.output_buf, -1, 0, -1)
  M.set_content({})
end

return M
