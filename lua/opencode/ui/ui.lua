local M = {}
local config = require('opencode.config')
local state = require('opencode.state')
local renderer = require('opencode.ui.output_renderer')
local output_window = require('opencode.ui.output_window')
local input_window = require('opencode.ui.input_window')
local footer = require('opencode.ui.footer')
local topbar = require('opencode.ui.topbar')

function M.scroll_to_bottom()
  local line_count = vim.api.nvim_buf_line_count(state.windows.output_buf)
  vim.api.nvim_win_set_cursor(state.windows.output_win, { line_count, 0 })

  vim.defer_fn(function()
    renderer.render_markdown()
  end, 200)
end

---@param windows OpencodeWindowState
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
  footer.close()

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
  local input_buf = input_window.create_buf()
  local output_buf = output_window.create_buf()
  local footer_buf = footer.create_buf()
  return { input_buf = input_buf, output_buf = output_buf, footer_buf = footer_buf }
end

---@param direction 'left' | 'right' | 'top' | 'bottom'
---@param type 'vertical' | 'horizontal'
local function open_split(direction, type)
  if type == 'vertical' then
    vim.cmd((direction == 'left' and 'leftabove' or 'rightbelow') .. ' vsplit')
  else
    vim.cmd((direction == 'top' and 'aboveleft' or 'belowright') .. ' split')
  end
  return vim.api.nvim_get_current_win()
end

function M.create_split_windows(input_buf, output_buf)
  if state.windows then
    M.close_windows(state.windows)
  end
  local ui_conf = config.get('ui')

  local main_win = open_split(ui_conf.position, 'vertical')
  vim.api.nvim_set_current_win(main_win)

  local input_win = open_split(ui_conf.input_position, 'horizontal')
  local output_win = main_win

  vim.api.nvim_win_set_buf(input_win, input_buf)
  vim.api.nvim_win_set_buf(output_win, output_buf)
  return { input_win = input_win, output_win = output_win }
end

function M.create_windows()
  require('opencode.ui.highlight').setup()
  vim.treesitter.language.register('markdown', 'opencode_output')

  local autocmds = require('opencode.ui.autocmds')

  if not require('opencode.ui.ui').is_opencode_focused() then
    require('opencode.context').load()
    state.last_code_win_before_opencode = vim.api.nvim_get_current_win()
  end

  local buffers = M.setup_buffers()
  local windows = buffers
  local win_ids = M.create_split_windows(buffers.input_buf, buffers.output_buf)

  windows.input_win = win_ids.input_win
  windows.output_win = win_ids.output_win

  input_window.setup(windows)
  output_window.setup(windows)
  footer.setup(windows)

  autocmds.setup_autocmds(windows)
  autocmds.setup_resize_handler(windows)

  return windows
end

function M.focus_input(opts)
  opts = opts or {}
  local windows = state.windows
  vim.api.nvim_set_current_win(windows.input_win)

  if opts.restore_position and state.last_input_window_position then
    pcall(vim.api.nvim_win_set_cursor, 0, state.last_input_window_position)
  end
  if opts.start_insert then
    vim.cmd('startinsert')
  end
end

function M.focus_output(opts)
  opts = opts or {}

  local windows = state.windows
  vim.api.nvim_set_current_win(windows.output_win)

  if opts.restore_position and state.last_output_window_position then
    pcall(vim.api.nvim_win_set_cursor, 0, state.last_output_window_position)
  end
end

function M.is_opencode_focused()
  if not state.windows then
    return false
  end
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
  renderer.stop()
  output_window.clear()
  footer.clear()
  topbar.render()
  renderer.render_markdown()
end

function M.render_output()
  renderer.render(state.windows, false)
end

function M.render_lines(lines)
  M.clear_output()
  renderer.write_output(state.windows, lines)
  renderer.render_markdown()
end

function M.stop_render_output()
  renderer.stop()
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
    output_window.focus_output(true)
  else
    input_window.focus_input()
  end
end

function M.swap_position()
  local ui_conf = config.get('ui')
  local new_pos = (ui_conf.position == 'left') and 'right' or 'left'
  config.values.ui.position = new_pos

  if state.windows then
    M.close_windows(state.windows)
  end
  vim.schedule(function()
    require('opencode.api').toggle(state.active_session == nil)
  end)
end

return M
