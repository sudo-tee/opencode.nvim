local state = require('opencode.state')
local config = require('opencode.config').get()
local M = {}

function M.create_buf()
  local input_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value('filetype', 'opencode', { buf = input_buf })
  return input_buf
end

function M._build_input_win_config()
  return {
    relative = 'editor',
    width = config.ui.window_width or 80,
    height = 3,
    col = 2,
    style = 'minimal',
    zindex = 41,
  }
end

function M.create_window(windows)
  windows.input_win = vim.api.nvim_open_win(windows.input_buf, true, M._build_input_win_config())
end

function M.mounted(windows)
  windows = windows or state.windows
  if not windows or not windows.input_buf or not windows.input_win then
    return false
  end

  return true
end

function M.close()
  if not M.mounted() then
    return
  end

  pcall(vim.api.nvim_win_close, state.windows.input_win, true)
  pcall(vim.api.nvim_buf_delete, state.windows.input_buf, { force = true })
end

function M.handle_submit()
  local windows = state.windows
  if not windows or not M.mounted(windows) then
    return
  end
  local input_content = table.concat(vim.api.nvim_buf_get_lines(windows.input_buf, 0, -1, false), '\n')
  vim.api.nvim_buf_set_lines(windows.input_buf, 0, -1, false, {})
  vim.api.nvim_exec_autocmds('TextChanged', {
    buffer = windows.input_buf,
    modeline = false,
  })

  vim.api.nvim_set_current_win(windows.output_win)

  local line_count = vim.api.nvim_buf_line_count(windows.output_buf)
  vim.api.nvim_win_set_cursor(windows.output_win, { line_count, 0 })

  require('opencode.core').send_message(input_content)
end

function M.setup(windows)
  vim.api.nvim_set_option_value('winhighlight', config.ui.window_highlight, { win = windows.input_win })
  vim.api.nvim_set_option_value('wrap', config.ui.input.text.wrap, { win = windows.input_win })
  vim.api.nvim_set_option_value('signcolumn', 'yes', { win = windows.input_win })
  vim.api.nvim_set_option_value('cursorline', false, { win = windows.input_win })
  vim.api.nvim_set_option_value('number', false, { win = windows.input_win })
  vim.api.nvim_set_option_value('relativenumber', false, { win = windows.input_win })
  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = windows.input_buf })
  vim.api.nvim_set_option_value('swapfile', false, { buf = windows.input_buf })
  -- vim.b[windows.input_buf].completion = false
  vim.api.nvim_set_option_value('winfixbuf', true, { win = windows.input_win })
  vim.api.nvim_set_option_value('winfixheight', true, { win = windows.input_win })
  vim.api.nvim_set_option_value('winfixwidth', true, { win = windows.input_win })

  M.update_dimensions(windows)
  M.refresh_placeholder(windows)
  M.setup_keymaps(windows)
  M.recover_input(windows)
end

function M.update_dimensions(windows)
  if not M.mounted(windows) then
    return
  end

  local total_width = vim.api.nvim_get_option_value('columns', {})
  local total_height = vim.api.nvim_get_option_value('lines', {})
  local width = math.floor(total_width * config.ui.window_width)
  local height = math.floor(total_height * config.ui.input_height)

  vim.api.nvim_win_set_config(windows.input_win, { width = width, height = height })
end

function M.refresh_placeholder(windows, input_lines)
  if not M.mounted(windows) then
    return
  end

  if not input_lines then
    input_lines = vim.api.nvim_buf_get_lines(windows.input_buf, 0, -1, false)
  end
  if #input_lines == 1 and input_lines[1] == '' then
    local ns_id = vim.api.nvim_create_namespace('input_placeholder')
    local win_width = vim.api.nvim_win_get_width(windows.input_win)
    local padding = string.rep(' ', win_width)
    local keys = config.keymap.window
    vim.api.nvim_buf_set_extmark(windows.input_buf, ns_id, 0, 0, {
      virt_text = {
        { 'Type your prompt here... ', 'OpenCodeHint' },
        { keys.slash_commands, 'OpencodeInputLegend' },
        { ' commands ', 'OpenCodeHint' },
        { keys.mention, 'OpencodeInputLegend' },
        { ' mentions ', 'OpenCodeHint' },
        { keys.mention_file, 'OpencodeInputLegend' },
        { ' to pick files' .. padding, 'OpenCodeHint' },
      },

      virt_text_pos = 'overlay',
    })
  else
    vim.api.nvim_buf_clear_namespace(windows.input_buf, vim.api.nvim_create_namespace('input_placeholder'), 0, -1)
  end
end

function M.clear_placeholder(windows)
  if not windows or not windows.input_buf then
    return
  end
  vim.api.nvim_buf_clear_namespace(windows.input_buf, vim.api.nvim_create_namespace('input_placeholder'), 0, -1)
end

function M.recover_input(windows)
  M.set_content(state.input_content)
  require('opencode.ui.mention').highlight_all_mentions(windows.input_buf)
end

function M.focus_input()
  vim.api.nvim_set_current_win(state.windows.input_win)

  local lines = vim.api.nvim_buf_get_lines(state.windows.input_buf, 0, -1, false)
  if #lines == 1 and lines[1] == '' then
    require('opencode.ui.input_window').refresh_placeholder(state.windows)
  else
    require('opencode.ui.input_window').clear_placeholder(state.windows)
  end
end

function M.set_content(text, windows)
  windows = windows or state.windows
  if not M.mounted(windows) then
    return
  end

  local lines = type(text) == 'table' and text or vim.split(tostring(text), '\n')

  vim.api.nvim_buf_set_lines(windows.input_buf, 0, -1, false, lines)
end

function M.is_empty()
  local windows = state.windows
  if not windows or not M.mounted() then
    return true
  end

  local lines = vim.api.nvim_buf_get_lines(windows.input_buf, 0, -1, false)
  return #lines == 0 or (#lines == 1 and lines[1] == '')
end

function M.setup_keymaps(windows)
  local map = require('opencode.keymap').buf_keymap
  local nav_history = require('opencode.ui.util').navigate_history
  local nav = require('opencode.ui.navigation')
  local core = require('opencode.core')
  local api = require('opencode.api')
  local completion = require('opencode.ui.completion')
  local keymaps = config.keymap.window
  local input_buf = windows.input_buf

  map(keymaps.submit, M.handle_submit, input_buf, 'n')
  map(keymaps.submit_insert, M.handle_submit, input_buf, 'i')

  map(keymaps.mention, completion.trigger_completion(keymaps.mention), input_buf, 'i')
  map(keymaps.slash_commands, completion.trigger_completion(keymaps.slash_commands), input_buf, 'i')
  map(keymaps.mention_file, core.add_file_to_context, input_buf, 'i')

  map(keymaps.prev_prompt_history, nav_history(keymaps.prev_prompt_history, 'prev'), input_buf, { 'n', 'i' })
  map(keymaps.next_prompt_history, nav_history(keymaps.next_prompt_history, 'next'), input_buf, { 'n', 'i' })

  map(keymaps.switch_mode, api.switch_to_next_mode, input_buf, { 'n', 'i' })

  map(keymaps.next_message, nav.goto_next_message, input_buf, 'n')
  map(keymaps.prev_message, nav.goto_prev_message, input_buf, 'n')

  map(keymaps.close, api.close, input_buf, 'n')
  map(keymaps.stop, api.stop, input_buf, 'n')
  map(keymaps.toggle_pane, api.toggle_pane, input_buf, { 'n', 'i' })

  map(keymaps.select_child_session, api.select_child_session, input_buf, 'n')

  if config.debug.enabled then
    local debug_helper = require('opencode.ui.debug_helper')
    map(keymaps.debug_output, debug_helper.debug_output, input_buf, 'n')
    map(keymaps.debug_session, debug_helper.debug_session, input_buf, 'n')
  end
end

function M.setup_autocmds(windows, group)
  vim.api.nvim_create_autocmd('WinEnter', {
    group = group,
    buffer = windows.input_buf,
    callback = function()
      M.refresh_placeholder(windows)
      state.last_focused_opencode_window = 'input'
    end,
  })

  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    buffer = windows.input_buf,
    callback = function()
      local input_lines = vim.api.nvim_buf_get_lines(windows.input_buf, 0, -1, false)
      state.input_content = input_lines
      M.refresh_placeholder(windows, input_lines)
    end,
  })
end

return M
