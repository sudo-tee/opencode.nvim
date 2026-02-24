local config = require('opencode.config')
local state = require('opencode.state')
local renderer = require('opencode.ui.renderer')
local output_window = require('opencode.ui.output_window')
local input_window = require('opencode.ui.input_window')
local footer = require('opencode.ui.footer')
local topbar = require('opencode.ui.topbar')

local M = {}

---Capture cursor positions from both windows for snapshot
---@param windows OpencodeWindowState
---@return {input: integer[]|nil, output: integer[]|nil}
local function capture_cursors_position(windows)
  return {
    input = state.get_window_cursor(windows.input_win),
    output = state.get_window_cursor(windows.output_win),
  }
end

---@param win_id integer|nil
---@param buf_id integer|nil
---@param cursor integer[]|nil
local function restore_window_cursor(win_id, buf_id, cursor)
  if not win_id or not vim.api.nvim_win_is_valid(win_id) then
    return
  end
  if not buf_id or not vim.api.nvim_buf_is_valid(buf_id) then
    return
  end
  if type(cursor) ~= 'table' or #cursor < 2 then
    return
  end

  local line_count = vim.api.nvim_buf_line_count(buf_id)
  if line_count <= 0 then
    return
  end

  local line = tonumber(cursor[1]) or 1
  local col = tonumber(cursor[2]) or 0

  line = math.max(1, math.min(math.floor(line), line_count))
  col = math.max(0, math.floor(col))

  local ok, line_text = pcall(vim.api.nvim_buf_get_lines, buf_id, line - 1, line, false)
  if ok then
    local text = line_text[1] or ''
    col = math.min(col, #text)
  end

  pcall(vim.api.nvim_win_set_cursor, win_id, { line, col })
end

---@param windows OpencodeWindowState
---@return OpencodeHiddenBuffers
local function capture_hidden_snapshot(windows)
  local current_win = vim.api.nvim_get_current_win()
  local focused = state.last_focused_opencode_window or 'input'
  if current_win == windows.output_win then
    focused = 'output'
  elseif current_win == windows.input_win then
    focused = 'input'
  end
  local ok, view = pcall(vim.api.nvim_win_call, windows.output_win, vim.fn.winsaveview)
  local cursor_positions = capture_cursors_position(windows)

  return {
    input_buf = windows.input_buf,
    output_buf = windows.output_buf,
    footer_buf = windows.footer_buf,
    output_was_at_bottom = output_window.is_at_bottom(windows.output_win),
    input_hidden = input_window.is_hidden(),
    input_cursor = cursor_positions.input,
    output_cursor = cursor_positions.output,
    output_view = ok and type(view) == 'table' and view or nil,
    focused_window = focused,
    position = config.ui.position,
    owner_tab = state.are_windows_in_current_tab()
      and vim.api.nvim_get_current_tabpage() or nil,
  }
end

---@param windows OpencodeWindowState?
---@param persist? boolean If true, preserve buffers for fast restore
function M.close_windows(windows, persist)
  local should_preserve = persist == true and config.ui.persist_state
  if should_preserve then
    return M.hide_visible_windows(windows)
  end
  return M.teardown_visible_windows(windows)
end

local function prepare_window_close()
  if M.is_opencode_focused() then M.return_to_last_code_win() end
  if state.display_route then state.display_route = nil end

  pcall(vim.api.nvim_del_augroup_by_name, 'OpencodeResize')
  pcall(vim.api.nvim_del_augroup_by_name, 'OpencodeWindows')
  pcall(vim.api.nvim_del_augroup_by_name, 'OpencodeFooterResize')

  topbar.close()
end

local function close_or_restore_output_window(windows)
  if config.ui.position == 'current' then
    if windows.output_win and vim.api.nvim_win_is_valid(windows.output_win) then
      pcall(vim.api.nvim_set_option_value, 'winfixbuf', false, { win = windows.output_win })
      if state.current_code_buf and vim.api.nvim_buf_is_valid(state.current_code_buf) then
        pcall(vim.api.nvim_win_set_buf, windows.output_win, state.current_code_buf)
      end
      if state.saved_window_options then
        for opt, value in pairs(state.saved_window_options) do
          pcall(vim.api.nvim_set_option_value, opt, value, { win = windows.output_win })
        end
        state.saved_window_options = nil
      end
    end
    return
  end

  pcall(vim.api.nvim_win_close, windows.output_win, true)
end

function M.hide_visible_windows(windows)
  if not windows then
    return
  end
  if not config.ui.persist_state then
    return M.teardown_visible_windows(windows)
  end

  local snapshot = capture_hidden_snapshot(windows)
  state.clear_hidden_window_state()

  prepare_window_close()
  footer.close(true)
  pcall(vim.api.nvim_win_close, windows.input_win, true)
  close_or_restore_output_window(windows)

  for _, buf in ipairs({ windows.input_buf, windows.output_buf, windows.footer_buf }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_set_option_value, 'bufhidden', 'hide', { buf = buf })
    end
  end
  if windows.input_buf and vim.api.nvim_buf_is_valid(windows.input_buf) then
    local ok, lines = pcall(vim.api.nvim_buf_get_lines, windows.input_buf, 0, -1, false)
    if ok then state.input_content = lines end
  end
  state.stash_hidden_buffers(snapshot)
  if state.windows == windows then
    state.windows.input_win = nil
    state.windows.output_win = nil
    state.windows.footer_win = nil
    state.windows.output_was_at_bottom = snapshot.output_was_at_bottom
  end
end

function M.teardown_visible_windows(windows)
  if not windows then
    return
  end

  prepare_window_close()
  renderer.teardown()
  footer.close(false)
  pcall(vim.api.nvim_win_close, windows.input_win, true)
  close_or_restore_output_window(windows)

  input_window._hidden = false
  pcall(vim.api.nvim_buf_delete, windows.input_buf, { force = true })
  pcall(vim.api.nvim_buf_delete, windows.output_buf, { force = true })
  if state.windows == windows then
    state.windows = nil
  end
  state.clear_hidden_window_state()
end

function M.drop_hidden_snapshot()
  renderer.teardown()

  local hidden = state.inspect_hidden_buffers()
  if hidden then
    for _, buf in ipairs({ hidden.input_buf, hidden.output_buf, hidden.footer_buf }) do
      if buf and vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
  end

  input_window._hidden = false
  state.clear_hidden_window_state()
end

---Restore windows using preserved buffers
---@return boolean success
function M.restore_hidden_windows()
  local hidden = state.inspect_hidden_buffers()
  if not hidden then
    return false
  end

  local autocmds = require('opencode.ui.autocmds')
  local footer_buf = hidden.footer_buf
  if not footer_buf or not vim.api.nvim_buf_is_valid(footer_buf) then
    footer_buf = footer.create_buf()
  end

  local win_ids = M.create_split_windows(hidden.input_buf, hidden.output_buf)

  state.consume_hidden_buffers()

  local windows = state.windows
  if not windows then
    windows = {}
    state.windows = windows
  end
  windows.input_buf = hidden.input_buf
  windows.output_buf = hidden.output_buf
  windows.footer_buf = footer_buf
  windows.input_win = win_ids.input_win
  windows.output_win = win_ids.output_win
  windows.footer_win = nil
  windows.output_was_at_bottom = hidden.output_was_at_bottom == true

  state.set_cursor_position('input', hidden.input_cursor)
  state.set_cursor_position('output', hidden.output_cursor)

  input_window.setup(windows)
  output_window.setup(windows)
  footer.setup(windows)
  if state.api_client and type(state.api_client.list_providers) == 'function' then
    topbar.setup()
  end

  autocmds.setup_autocmds(windows)
  autocmds.setup_resize_handler(windows)

  if hidden.input_hidden then
    input_window._hide()
  end

  vim.schedule(function()
    local w = state.windows
    if not w then return end

    if hidden.output_was_at_bottom then
      renderer.scroll_to_bottom(true)
    else
      restore_window_cursor(w.output_win, w.output_buf, state.get_cursor_position('output'))
      if type(hidden.output_view) == 'table' then
        pcall(vim.api.nvim_win_call, w.output_win, function()
          vim.fn.winrestview(hidden.output_view)
        end)
      end
    end

    if not hidden.input_hidden then
      restore_window_cursor(w.input_win, w.input_buf, state.get_cursor_position('input'))
    end
  end)

  require('opencode.ui.contextual_actions').setup_contextual_actions(windows)

  return true
end

---Check if we have valid hidden buffers
---@return boolean
function M.has_hidden_buffers()
  return state.has_hidden_buffers()
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
  if input_window.mounted() or output_window.mounted() then
    M.close_windows(state.windows, false)
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

  if ui_conf.position == 'current' then
    pcall(vim.api.nvim_set_option_value, 'winfixbuf', false, { win = output_win })
  end

  vim.api.nvim_win_set_buf(input_win, input_buf)
  vim.api.nvim_win_set_buf(output_win, output_buf)
  return { input_win = input_win, output_win = output_win }
end

function M.create_windows()
  vim.treesitter.language.register('markdown', 'opencode_output')
  vim.treesitter.language.register('markdown', 'opencode')

  local autocmds = require('opencode.ui.autocmds')

  if not require('opencode.ui.ui').is_opencode_focused() then
    state.last_code_win_before_opencode = vim.api.nvim_get_current_win()
    state.current_code_buf = vim.api.nvim_get_current_buf()
  end

  -- Create new windows from scratch
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

  local was_input_focused = vim.api.nvim_get_current_win() == windows.input_win

  if input_window.is_hidden() then
    input_window._show()
    was_input_focused = false
  end

  if not windows.input_win then
    return
  end

  vim.api.nvim_set_current_win(windows.input_win)

  if opts.restore_position and not was_input_focused and state.last_input_window_position then
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
---@param opts? {force_scroll?: boolean}
function M.render_output(synchronous, opts)
  local ret = renderer.render_full_session(opts)

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
    M.close_windows(state.windows, false)
  end
  vim.schedule(function()
    require('opencode.api').toggle(state.active_session == nil)
  end)
end

function M.toggle_zoom()
  local windows = state.windows
  if not windows or not (windows.output_win or windows.input_win) then
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

  local function resize_window(win)
    if not win or not vim.api.nvim_win_is_valid(win) then
      return
    end

    local win_config = vim.api.nvim_win_get_config(win)
    if win_config.relative ~= '' then
      vim.api.nvim_win_set_config(win, { width = width })
    else
      vim.api.nvim_win_set_width(win, width)
    end
  end

  if windows.input_win ~= nil then
    resize_window(windows.input_win)
  end
  if windows.output_win ~= nil then
    resize_window(windows.output_win)
  end
end

return M
