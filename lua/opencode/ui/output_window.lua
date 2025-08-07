local state = require('opencode.state')
local config = require('opencode.config').get()

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
  if not state.windows or not state.windows.output_buf or not state.windows.output_win then
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

  M.update_dimensions(windows)
  M.setup_keymaps(windows)
  state.subscribe('restore_points', function(_, new_val, old_val)
    local outout_renderer = require('opencode.ui.output_renderer')
    outout_renderer.render(windows, true)
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
  vim.api.nvim_buf_set_lines(windows.output_buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = windows.output_buf })
  M.append_content({ '', '' })
end

function M.append_content(lines)
  if not M.mounted() then
    return
  end

  local windows = state.windows
  if not windows or not windows.output_buf then
    return
  end
  vim.api.nvim_set_option_value('modifiable', true, { buf = windows.output_buf })
  local current_lines = vim.api.nvim_buf_get_lines(windows.output_buf, 0, -1, false)
  vim.api.nvim_buf_set_lines(windows.output_buf, #current_lines, -1, false, lines)
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
  local ui = require('opencode.ui.ui')
  local api = require('opencode.api')
  local map = require('opencode.keymap').buf_keymap
  local nav = require('opencode.ui.navigation')

  local keymaps = config.keymap.window
  local output_buf = windows.output_buf

  map(keymaps.close, api.close, output_buf, 'n')

  map(keymaps.next_message, nav.goto_next_message, output_buf, 'n')
  map(keymaps.prev_message, nav.goto_prev_message, output_buf, 'n')

  map(keymaps.stop, api.stop, output_buf, { 'n' })

  map(keymaps.toggle_pane, api.toggle_pane, output_buf, { 'n' })

  map(keymaps.focus_input, function()
    ui.focus_input({ restore_position = true, start_insert = true })
  end, output_buf, 'n')

  map(keymaps.switch_mode, api.switch_to_next_mode, output_buf, 'n')

  if config.debug.enabled then
    local debug_helper = require('opencode.ui.debug_helper')
    map(keymaps.debug_output, debug_helper.debug_output, output_buf, 'n')
    map(keymaps.debug_message, debug_helper.debug_message, output_buf, 'n')
  end
end

function M.setup_autocmds(windows, group)
  vim.api.nvim_create_autocmd('WinEnter', {
    group = group,
    buffer = windows.output_buf,
    callback = function()
      vim.cmd('stopinsert')
      state.last_focused_opencode_window = 'output'
      require('opencode.ui.input_window').refresh_placeholder(windows)
    end,
  })

  vim.api.nvim_create_autocmd('BufEnter', {
    group = group,
    buffer = windows.output_buf,
    callback = function()
      vim.cmd('stopinsert')
      state.last_focused_opencode_window = 'output'
      require('opencode.ui.input_window').refresh_placeholder(windows)
    end,
  })
end

function M.clear()
  vim.api.nvim_buf_clear_namespace(state.windows.output_buf, -1, 0, -1)
  M.set_content({})
end

return M
