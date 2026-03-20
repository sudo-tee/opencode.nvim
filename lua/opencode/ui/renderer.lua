local state = require('opencode.state')
local config = require('opencode.config')
local formatter = require('opencode.ui.formatter')
local output_window = require('opencode.ui.output_window')
local permission_window = require('opencode.ui.permission_window')
local Promise = require('opencode.promise')
local ctx = require('opencode.ui.renderer.ctx')
local buf = require('opencode.ui.renderer.buffer')
local events = require('opencode.ui.renderer.events')

local M = {}

-- Expose event handlers on M so tests can call them directly and subscriptions
-- can be stubbed cleanly (e.g. stub(renderer, '_render_full_session_data'))
M.on_session_updated = events.on_session_updated

local trigger_on_data_rendered = require('opencode.util').debounce(function()
  local cb_type = type(config.ui.output.rendering.on_data_rendered)
  if cb_type == 'boolean' then
    return
  end
  if not state.windows or not state.windows.output_buf or not state.windows.output_win then
    return
  end
  if cb_type == 'function' then
    pcall(config.ui.output.rendering.on_data_rendered, state.windows.output_buf, state.windows.output_win)
  elseif vim.fn.exists(':RenderMarkdown') > 0 then
    vim.cmd(':RenderMarkdown')
  elseif vim.fn.exists(':Markview') > 0 then
    vim.cmd(':Markview render ' .. state.windows.output_buf)
  end
end, config.ui.output.rendering.markdown_debounce_ms or 250)

---Reset all renderer state and clear the output buffer
function M.reset()
  ctx:reset()
  output_window.clear()

  local permissions = state.pending_permissions or {}
  if #permissions > 0 and state.api_client then
    for _, permission in ipairs(permissions) do
      require('opencode.api').permission_deny(permission)
    end
  end
  permission_window.clear_all()
  state.renderer.reset()

  trigger_on_data_rendered()
end

---Unsubscribe from all events and reset
function M.teardown()
  M.setup_subscriptions(false)
  M.reset()
end

---Subscribe to (or unsubscribe from) all renderer events
---@param subscribe? boolean  false to unsubscribe (default true)
function M.setup_subscriptions(subscribe)
  subscribe = subscribe == nil and true or subscribe

  if subscribe then
    state.store.subscribe('is_opencode_focused', M.on_focus_changed)
    state.store.subscribe('active_session', M.on_session_changed)
  else
    state.store.unsubscribe('is_opencode_focused', M.on_focus_changed)
    state.store.unsubscribe('active_session', M.on_session_changed)
  end

  if not state.event_manager then
    return
  end

  local subs = {
    { 'session.updated',               events.on_session_updated },
    { 'session.compacted',             events.on_session_compacted },
    { 'session.error',                 events.on_session_error },
    { 'message.updated',               events.on_message_updated },
    { 'message.removed',               events.on_message_removed },
    { 'message.part.updated',          events.on_part_updated },
    { 'message.part.removed',          events.on_part_removed },
    { 'permission.updated',            events.on_permission_updated },
    { 'permission.asked',              events.on_permission_updated },
    { 'permission.replied',            events.on_permission_replied },
    { 'question.asked',                events.on_question_asked },
    { 'question.replied',              events.clear_question_display },
    { 'question.rejected',             events.clear_question_display },
    { 'file.edited',                   events.on_file_edited },
    { 'custom.restore_point.created',  events.on_restore_points },
    { 'custom.emit_events.finished',   M.on_emit_events_finished },
  }

  for _, sub in ipairs(subs) do
    if subscribe then
      state.event_manager:subscribe(sub[1], sub[2])
    else
      state.event_manager:unsubscribe(sub[1], sub[2])
    end
  end
end

---Fetch all messages for the active session from the server
---@return Promise<OpencodeMessage[]>
local function fetch_session()
  local session = state.active_session
  if not session or session == '' then
    return Promise.new():resolve(nil)
  end
  state.renderer.set_last_user_message(nil)
  return require('opencode.session').get_messages(session)
end

---Set the current model/mode from the most recent assistant message
local function set_model_and_mode_from_messages()
  if not state.messages then
    return
  end
  for i = #state.messages, 1, -1 do
    local message = state.messages[i]
    if message and message.info and message.info.modelID and message.info.providerID then
      state.model.set_model(message.info.providerID .. '/' .. message.info.modelID)
      if message.info.mode then
        state.model.set_mode(message.info.mode)
      end
      return
    end
  end
  require('opencode.core').initialize_current_model()
end

---Render all messages and parts from session_data into the output buffer
---Called after a full session fetch or when revert state changes
---@param session_data OpencodeMessage[]
function M._render_full_session_data(session_data)
  M.reset()

  if not state.active_session or not state.messages then
    return
  end

  local revert_index = nil
  local set_mode_from_messages = not state.current_model

  for i, msg in ipairs(session_data) do
    if state.active_session.revert and state.active_session.revert.messageID == msg.info.id then
      revert_index = i
    end
    events.on_message_updated({ info = msg.info }, revert_index)
    for _, part in ipairs(msg.parts or {}) do
      events.on_part_updated({ part = part }, revert_index)
    end
  end

  if revert_index then
    buf.write_formatted_data(formatter._format_revert_message(state.messages, revert_index))
  end

  if set_mode_from_messages then
    set_model_and_mode_from_messages()
  end

  M.scroll_to_bottom(true)

  if config.hooks and config.hooks.on_session_loaded then
    pcall(config.hooks.on_session_loaded, state.active_session)
  end
end

---Fetch the active session from the server and render it
---@return Promise<OpencodeMessage[]>
function M.render_full_session()
  if not output_window.mounted() or not state.api_client then
    return Promise.new():resolve(nil)
  end
  return fetch_session():and_then(M._render_full_session_data)
end

---Replace the entire output buffer with the given lines
---@param lines string[]
function M.render_lines(lines)
  local output = require('opencode.ui.output'):new()
  output.lines = lines
  M.render_output(output)
end

---Replace the entire output buffer with formatted output data
---@param output_data Output
function M.render_output(output_data)
  if not output_window.buffer_valid() then
    return
  end
  output_window.set_lines(output_data.lines or {})
  output_window.clear_extmarks()
  output_window.set_extmarks(output_data.extmarks)
  M.scroll_to_bottom()
end

---Scroll the output window to the bottom.
---Respects the user's scroll position unless force=true or conditions allow it.
---@param force? boolean
function M.scroll_to_bottom(force)
  local windows = state.windows
  local output_win = windows and windows.output_win
  local output_buf = windows and windows.output_buf

  if not output_buf or not output_win then
    return
  end
  if not vim.api.nvim_win_is_valid(output_win) then
    return
  end

  local ok, line_count = pcall(vim.api.nvim_buf_line_count, output_buf)
  if not ok or line_count == 0 then
    return
  end

  local prev_line_count = ctx.prev_line_count
  ctx.prev_line_count = line_count

  trigger_on_data_rendered()

  local should_scroll = force
    or prev_line_count == 0
    or config.ui.output.always_scroll_to_bottom
    or (function()
         local ok_cursor, cursor = pcall(vim.api.nvim_win_get_cursor, output_win)
         return ok_cursor and cursor and (cursor[1] >= prev_line_count or cursor[1] >= line_count)
       end)()

  if should_scroll then
    vim.api.nvim_win_set_cursor(output_win, { line_count, 0 })
    vim.api.nvim_win_call(output_win, function()
      vim.cmd('normal! zb')
    end)
  end
end

---Re-render the permission display when focus changes (updates shortcut hints)
function M.on_focus_changed()
  if not permission_window.get_all_permissions()[1] then
    return
  end
  buf.rerender_part('permission-display-part')
  trigger_on_data_rendered()
end

---Re-render when the active session changes
function M.on_session_changed(_, new, old)
  if (old and old.id) == (new and new.id) then
    return
  end
  M.reset()
  if new then
    M.render_full_session()
  end
end

---Scroll to bottom after all queued events have been processed
function M.on_emit_events_finished()
  M.scroll_to_bottom()
end

---Return all actions available at a given (0-indexed) line
---@param line integer
---@return table[]
function M.get_actions_for_line(line)
  return ctx.render_state:get_actions_at_line(line)
end

---Return the rendered message record for a given message ID
---@param message_id string
---@return RenderedMessage|nil
function M.get_rendered_message(message_id)
  return ctx.render_state:get_message(message_id) or nil
end

return M
