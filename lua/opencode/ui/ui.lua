local M = {}
local config = require('opencode.config')
local state = require('opencode.state')
local renderer = require('opencode.ui.output_renderer')

function M.scroll_to_bottom()
  local line_count = vim.api.nvim_buf_line_count(state.windows.output_buf)
  vim.api.nvim_win_set_cursor(state.windows.output_win, { line_count, 0 })

  vim.defer_fn(function()
    renderer.render_markdown()
  end, 200)
end

function M.close_windows(windows)
  if not windows then
    return
  end

  if M.is_opencode_focused() then
    M.return_to_last_code_win()
  end

  renderer.stop()

  -- Close windows and delete buffers
  pcall(vim.api.nvim_win_close, windows.input_win, true)
  pcall(vim.api.nvim_win_close, windows.output_win, true)
  pcall(vim.api.nvim_buf_delete, windows.input_buf, { force = true })
  pcall(vim.api.nvim_buf_delete, windows.output_buf, { force = true })

  -- Clear autocmd groups
  pcall(vim.api.nvim_del_augroup_by_name, 'OpencodeResize')
  pcall(vim.api.nvim_del_augroup_by_name, 'OpencodeWindows')

  state.windows = nil
end

function M.return_to_last_code_win()
  local last_win = state.last_code_win_before_opencode
  if last_win and vim.api.nvim_win_is_valid(last_win) then
    vim.api.nvim_set_current_win(last_win)
  end
end

function M.setup_buffers()
  local input_buf = vim.api.nvim_create_buf(false, true)
  local output_buf = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_set_option_value('filetype', 'opencode_input', { buf = input_buf })
  vim.api.nvim_set_option_value('filetype', 'opencode_output', { buf = output_buf })
  return { input_buf = input_buf, output_buf = output_buf }
end

function M.create_floating_windows(input_buf, output_buf, opts)
  local input_win = vim.api.nvim_open_win(input_buf, false, opts)
  local output_win = vim.api.nvim_open_win(output_buf, false, opts)
  return { input_win = input_win, output_win = output_win }
end

function M.create_split_windows(input_buf, output_buf)
  if state.windows then
    M.close_windows(state.windows)
  end
  vim.cmd('wincmd l')
  vim.cmd('vsplit')
  local output_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(output_win, output_buf)
  vim.cmd('split')
  local input_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(input_win, input_buf)
  return { input_win = input_win, output_win = output_win }
end

function M.create_windows()
  require('opencode.ui.highlight').setup()
  vim.treesitter.language.register('markdown', 'opencode_output')

  local configurator = require('opencode.ui.window_config')

  if not require('opencode.ui.ui').is_opencode_focused() then
    require('opencode.context').load()
    state.last_code_win_before_opencode = vim.api.nvim_get_current_win()
  end

  local buffers = M.setup_buffers()
  local windows = config.get('ui').floating
      and M.create_floating_windows(buffers.input_buf, buffers.output_buf, configurator.floating_win_opts)
    or M.create_split_windows(buffers.input_buf, buffers.output_buf)

  local wins_and_bufs = vim.tbl_extend('error', buffers, windows)

  configurator.setup_options(wins_and_bufs)
  configurator.refresh_placeholder(wins_and_bufs)
  configurator.setup_autocmds(wins_and_bufs)
  configurator.setup_resize_handler(wins_and_bufs)
  configurator.setup_keymaps(wins_and_bufs)
  configurator.setup_after_actions(wins_and_bufs)
  configurator.configure_window_dimensions(wins_and_bufs)

  return wins_and_bufs
end

function M.focus_input(opts)
  opts = opts or {}
  local windows = state.windows
  vim.api.nvim_set_current_win(windows.input_win)

  if opts.restore_position and state.last_input_window_position then
    vim.api.nvim_win_set_cursor(0, state.last_input_window_position)
  end
end

function M.focus_output(opts)
  opts = opts or {}

  local windows = state.windows
  vim.api.nvim_set_current_win(windows.output_win)

  if opts.restore_position and state.last_output_window_position then
    vim.api.nvim_win_set_cursor(0, state.last_output_window_position)
  end
end

function M.is_opencode_focused()
  if not state.windows then
    return false
  end
  -- are we in a opencode window?
  local current_win = vim.api.nvim_get_current_win()
  return M.is_opencode_window(current_win)
end

function M.is_opencode_window(win)
  local windows = state.windows
  return win == windows.input_win or win == windows.output_win
end

function M.is_output_empty()
  local windows = state.windows
  if not windows or not windows.output_buf then
    return true
  end
  local lines = vim.api.nvim_buf_get_lines(windows.output_buf, 0, -1, false)
  return #lines == 0 or (#lines == 1 and lines[1] == '')
end

function M.clear_output()
  local windows = state.windows

  -- Clear any extmarks/namespaces first
  local ns_id = vim.api.nvim_create_namespace('loading_animation')
  vim.api.nvim_buf_clear_namespace(windows.output_buf, ns_id, 0, -1)

  -- Stop any running timers in the output module
  if renderer._animation.timer then
    pcall(vim.fn.timer_stop, renderer._animation.timer)
    renderer._animation.timer = nil
  end
  if renderer._refresh_timer then
    pcall(vim.fn.timer_stop, renderer._refresh_timer)
    renderer._refresh_timer = nil
  end

  -- Reset animation state
  renderer._animation.loading_line = nil

  -- Clear cache to force refresh on next render
  renderer._cache = {
    last_modified = 0,
    output_lines = nil,
    session_path = nil,
    check_counter = 0,
  }

  -- Clear all buffer content
  vim.api.nvim_set_option_value('modifiable', true, { buf = windows.output_buf })
  vim.api.nvim_buf_set_lines(windows.output_buf, 0, -1, false, {})
  vim.api.nvim_set_option_value('modifiable', false, { buf = windows.output_buf })

  require('opencode.ui.topbar').render()
  renderer.render_markdown()
end

function M.render_output()
  renderer.render(state.windows, false)
end

function M.render_lines(lines)
  M.clear_output()
  renderer.write_output(state.windows, lines)
end

function M.stop_render_output()
  renderer.stop()
end

function M.toggle_fullscreen()
  local windows = state.windows
  if not windows then
    return
  end

  local ui_config = require('opencode.config').get('ui')
  if not ui_config.floating then
    vim.notify('Fullscreen mode is only available in floating window mode', vim.log.levels.WARN)
    return
  end
  ui_config.fullscreen = not ui_config.fullscreen

  require('opencode.ui.window_config').configure_floating_window_dimensions(windows)
  require('opencode.ui.topbar').render()

  if not M.is_opencode_focused() then
    vim.api.nvim_set_current_win(windows.output_win)
  end
end

function M.select_session(sessions, cb)
  local util = require('opencode.util')

  vim.ui.select(sessions, {
    prompt = '',
    format_item = function(session)
      local parts = {}

      if session.description then
        table.insert(parts, session.description)
      end

      if session.message_count then
        table.insert(parts, session.message_count .. ' messages')
      end

      local modified = util.time_ago(session.modified)
      if modified then
        table.insert(parts, modified)
      end

      return table.concat(parts, ' ~ ')
    end,
  }, function(session_choice)
    cb(session_choice)
  end)
end

function M.toggle_pane()
  local current_win = vim.api.nvim_get_current_win()
  if current_win == state.windows.input_win then
    -- When moving from input to output, exit insert mode first
    vim.cmd('stopinsert')
    vim.api.nvim_set_current_win(state.windows.output_win)
  else
    -- When moving from output to input, just change window
    -- (don't automatically enter insert mode)
    vim.api.nvim_set_current_win(state.windows.input_win)

    -- Fix placeholder text when switching to input window
    local lines = vim.api.nvim_buf_get_lines(state.windows.input_buf, 0, -1, false)
    if #lines == 1 and lines[1] == '' then
      -- Only show placeholder if the buffer is empty
      require('opencode.ui.window_config').refresh_placeholder(state.windows)
    else
      -- Clear placeholder if there's text in the buffer
      vim.api.nvim_buf_clear_namespace(
        state.windows.input_buf,
        vim.api.nvim_create_namespace('input-placeholder'),
        0,
        -1
      )
    end
  end
end

function M.write_to_input(text, windows)
  if not windows then
    windows = state.windows
  end
  if not windows then
    return
  end

  -- Check if input_buf is valid
  if
    not windows.input_buf
    or type(windows.input_buf) ~= 'number'
    or not vim.api.nvim_buf_is_valid(windows.input_buf)
  then
    return
  end

  local lines

  -- Check if text is already a table/list of lines
  if type(text) == 'table' then
    lines = text
  else
    -- If it's a string, split it into lines
    lines = {}
    for line in (text .. '\n'):gmatch('(.-)\n') do
      table.insert(lines, line)
    end

    -- If no newlines were found (empty result), use the original text
    if #lines == 0 then
      lines = { text }
    end
  end

  vim.api.nvim_buf_set_lines(windows.input_buf, 0, -1, false, lines)
end

return M
