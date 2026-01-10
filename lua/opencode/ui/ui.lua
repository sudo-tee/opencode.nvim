local config = require('opencode.config')
local state = require('opencode.state')
local renderer = require('opencode.ui.renderer')
local output_window = require('opencode.ui.output_window')
local input_window = require('opencode.ui.input_window')
local footer = require('opencode.ui.footer')
local topbar = require('opencode.ui.topbar')

local M = {}

---@param windows OpencodeWindowState?
function M.close_windows(windows)
  if not windows then
    return
  end

  if M.is_opencode_focused() then
    M.return_to_last_code_win()
  end

  topbar.close()
  renderer.teardown()

  pcall(vim.api.nvim_del_augroup_by_name, 'OpencodeResize')
  pcall(vim.api.nvim_del_augroup_by_name, 'OpencodeWindows')

  ---@cast windows { input_win: integer, output_win: integer, input_buf: integer, output_buf: integer }
  pcall(vim.api.nvim_win_close, windows.input_win, true)
  if config.ui.position == 'current' then
    pcall(vim.api.nvim_set_option_value, 'winfixbuf', false, { win = windows.output_win })
    if state.current_code_buf and vim.api.nvim_buf_is_valid(state.current_code_buf) then
      pcall(vim.api.nvim_win_set_buf, windows.output_win, state.current_code_buf)
    end
  else
    pcall(vim.api.nvim_win_close, windows.output_win, true)
  end
  pcall(vim.api.nvim_buf_delete, windows.input_buf, { force = true })
  pcall(vim.api.nvim_buf_delete, windows.output_buf, { force = true })
  footer.close()

  if state.windows == windows then
    state.windows = nil
  end
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
    vim.cmd((direction == 'left' and 'topleft' or 'botright') .. ' vsplit')
  else
    vim.cmd((direction == 'top' and 'aboveleft' or 'belowright') .. ' split')
  end
  return vim.api.nvim_get_current_win()
end

function M.create_split_windows(input_buf, output_buf)
  if state.windows then
    M.close_windows(state.windows)
  end
  local ui_conf = config.ui

  local main_win
  if ui_conf.position == 'current' then
    main_win = vim.api.nvim_get_current_win()
  else
    main_win = open_split(ui_conf.position, 'vertical')
  end
  vim.api.nvim_set_current_win(main_win)

  local input_win = open_split(ui_conf.input_position, 'horizontal')
  local output_win = main_win

  vim.api.nvim_win_set_buf(input_win, input_buf)
  vim.api.nvim_win_set_buf(output_win, output_buf)
  return { input_win = input_win, output_win = output_win }
end

function M.create_windows()
  vim.treesitter.language.register('markdown', 'opencode_output')

  local autocmds = require('opencode.ui.autocmds')

  if not require('opencode.ui.ui').is_opencode_focused() then
    state.last_code_win_before_opencode = vim.api.nvim_get_current_win()
    state.current_code_buf = vim.api.nvim_get_current_buf()
  end

  local buffers = M.setup_buffers()
  local windows = buffers
  local win_ids = M.create_split_windows(buffers.input_buf, buffers.output_buf)

  windows.input_win = win_ids.input_win
  windows.output_win = win_ids.output_win

  input_window.setup(windows)
  output_window.setup(windows)
  footer.setup(windows)
  topbar.setup()

  renderer.setup_subscriptions()

  autocmds.setup_autocmds(windows)
  autocmds.setup_resize_handler(windows)
  require('opencode.ui.contextual_actions').setup_contextual_actions(windows)

  return windows
end

function M.focus_input(opts)
  opts = opts or {}
  local windows = state.windows
  if not windows then
    return
  end

  if input_window.is_hidden() then
    input_window._show()
    return
  end

  if not windows.input_win then
    return
  end

  vim.api.nvim_set_current_win(windows.input_win)

  if opts.restore_position and state.last_input_window_position then
    pcall(vim.api.nvim_win_set_cursor, 0, state.last_input_window_position)
  end
  if vim.api.nvim_get_current_win() == windows.input_win and opts.start_insert then
    if vim.fn.mode() ~= 'i' then
      vim.api.nvim_feedkeys('a', 'n', false)
    end
  end
end

function M.focus_output(opts)
  opts = opts or {}
  local windows = state.windows
  if not windows or not windows.output_win then
    return
  end

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
  if not windows then
    return false
  end
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
  renderer.reset()
  output_window.clear()
  footer.clear()
  -- state.restore_points = {}
end

---Force a full rerender of the output buffer. Should be done synchronously if
---called before submitting input or doing something that might generate events
---from opencode
---@param synchronous? boolean If true, waits until session is fully rendered
function M.render_output(synchronous)
  local ret = renderer.render_full_session()

  if ret and synchronous then
    ret:wait()
  end
end

function M.render_lines(lines)
  M.clear_output()
  renderer.render_lines(lines)
end

function M.select_session(sessions, cb)
  local session_picker = require('opencode.ui.session_picker')
  local util = require('opencode.util')
  local picker = require('opencode.ui.picker')

  local success = session_picker.pick(sessions, cb)
  if not success then
    picker.select(sessions, {
      prompt = '',
      format_item = function(session)
        local parts = {}

        if session.title then
          table.insert(parts, session.title)
        else
          table.insert(parts, session.id)
        end

        local modified = util.format_time(session.modified)
        if modified then
          table.insert(parts, modified)
        end

        return table.concat(parts, ' ~ ')
      end,
    }, function(session_choice)
      cb(session_choice)
    end)
  end
end

function M.toggle_pane()
  local current_win = vim.api.nvim_get_current_win()
  if state.windows and current_win == state.windows.input_win then
    output_window.focus_output(true)
  else
    input_window.focus_input()
  end
end

function M.swap_position()
  local ui_conf = config.ui
  local new_pos = (ui_conf.position == 'left') and 'right' or 'left'
  config.values.ui.position = new_pos

  if state.windows then
    M.close_windows(state.windows)
  end
  vim.schedule(function()
    require('opencode.api').toggle(state.active_session == nil)
  end)
end

function M.toggle_zoom()
  local windows = state.windows
  if not windows or not windows.output_win or not windows.input_win then
    return
  end

  local width

  if state.pre_zoom_width then
    width = state.pre_zoom_width
    state.pre_zoom_width = nil
  else
    state.pre_zoom_width = vim.api.nvim_win_get_width(windows.output_win)
    width = math.floor(config.ui.zoom_width * vim.o.columns)
  end

  vim.api.nvim_win_set_config(windows.input_win, { width = width })
  vim.api.nvim_win_set_config(windows.output_win, { width = width })
end

return M
