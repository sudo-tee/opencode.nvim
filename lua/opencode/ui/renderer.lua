local state = require('opencode.state')
local config = require('opencode.config')
local output_window = require('opencode.ui.output_window')
local permission_window = require('opencode.ui.permission_window')
local Promise = require('opencode.promise')
local ctx = require('opencode.ui.renderer.ctx')
local events = require('opencode.ui.renderer.events')
local flush = require('opencode.ui.renderer.flush')
local scroll = require('opencode.ui.renderer.scroll')

local M = {}

-- Expose event handlers on M so tests can call them directly and subscriptions
-- can be stubbed cleanly (e.g. stub(renderer, '_render_full_session_data'))
M.on_session_updated = events.on_session_updated

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

  flush.trigger_on_data_rendered()
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

---Render all messages and parts from session_data into the output buffer
---Called after a full session fetch or when revert state changes
---@param session_data OpencodeMessage[]
---@param opts? { restore_model_from_messages?: boolean }
function M._render_full_session_data(session_data, opts)
  opts = opts or {}
  M.reset()

  if not state.active_session or not state.messages then
    return
  end

  local revert_index = nil

  flush.begin_bulk_mode()

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
    local revert_message = {
      info = {
        id = '__opencode_revert_message__',
        sessionID = state.active_session.id,
        role = 'system',
      },
      parts = {
        {
          id = '__opencode_revert_part__',
          messageID = '__opencode_revert_message__',
          sessionID = state.active_session.id,
          type = 'revert-display',
          state = {
            revert_index = revert_index,
          },
        },
      },
    }

    events.on_message_updated(revert_message)
    events.on_part_updated({ part = revert_message.parts[1] })
  end

  flush.flush()
  flush.end_bulk_mode()

  if opts.restore_model_from_messages then
    require('opencode.core').initialize_current_model({ restore_from_messages = true })
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
  return fetch_session():and_then(function(session_data)
    M._render_full_session_data(session_data, { restore_model_from_messages = true })
    local active_session = state.active_session
    if active_session and active_session.id then
      require('opencode.ui.question_window').restore_pending_question(active_session.id)
    end
    return session_data
  end)
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
  flush.trigger_on_data_rendered()
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

  if force or config.ui.output.always_scroll_to_bottom or output_window.is_at_bottom(output_win) then
    scroll.scroll_win_to_bottom(output_win, output_buf)
  end
end

---Re-render the permission display when focus changes (updates shortcut hints)
function M.on_focus_changed()
  if not permission_window.get_all_permissions()[1] then
    return
  end
  flush.mark_part_dirty('permission-display-part', 'permission-display-message')
  flush.flush()
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

---@param current_line integer
---@return RenderedMessage|nil
function M.get_next_rendered_message(current_line)
  local next_message = nil

  for _, message in ipairs(state.messages or {}) do
    local rendered = message.info and message.info.id and ctx.render_state:get_message(message.info.id) or nil
    if rendered and rendered.line_start and rendered.line_start + 1 > current_line then
      next_message = rendered
      break
    end
  end

  return next_message
end

---@param current_line integer
---@return RenderedMessage|nil
function M.get_prev_rendered_message(current_line)
  for i = #(state.messages or {}), 1, -1 do
    local message = state.messages[i]
    local rendered = message and message.info and message.info.id and ctx.render_state:get_message(message.info.id) or nil
    if rendered and rendered.line_start and rendered.line_start + 1 < current_line then
      return rendered
    end
  end

  return nil
end

return M
