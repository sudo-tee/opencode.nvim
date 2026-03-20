local state = require('opencode.state')
local config = require('opencode.config')
local formatter = require('opencode.ui.formatter')
local output_window = require('opencode.ui.output_window')
local permission_window = require('opencode.ui.permission_window')
local Promise = require('opencode.promise')
local RenderState = require('opencode.ui.render_state')
local buf = require('opencode.ui.renderer.buffer')
local events = require('opencode.ui.renderer.events')

-- ─── Module state ─────────────────────────────────────────────────────────────

local M = {
  _prev_line_count = 0,
  _render_state = RenderState.new(),
  _last_formatted = { part_id = nil, formatted_data = nil },
}

-- ─── Context object ───────────────────────────────────────────────────────────
-- Passed to every event handler so they don't need to require this module.

---Build the context table that event handlers receive.
---@return table ctx
local function make_ctx()
  return {
    render_state = M._render_state,
    buf = buf,
    last_formatted = M._last_formatted,
    scroll_to_bottom = function(force)
      M.scroll_to_bottom(force)
    end,
    render_full_session = function()
      M._render_full_session_data(state.messages)
    end,
    render_permissions_display = function()
      M.render_permissions_display()
    end,
  }
end

-- ─── Markdown debounce ────────────────────────────────────────────────────────

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

local function on_focus_changed()
  events.on_focus_changed(make_ctx())
  trigger_on_data_rendered()
end

local function on_question_replied() M.clear_question_display() end
local function on_emit_events_finished() M.scroll_to_bottom() end

-- Stable references so unsubscribe can match by identity.
local event_subs = {
  { 'session.updated',              function(...) events.on_session_updated(make_ctx(), ...) end },
  { 'session.compacted',            function(...) events.on_session_compacted(make_ctx(), ...) end },
  { 'session.error',                function(...) events.on_session_error(make_ctx(), ...) end },
  { 'message.updated',              function(...) events.on_message_updated(make_ctx(), ...) end },
  { 'message.removed',              function(...) events.on_message_removed(make_ctx(), ...) end },
  { 'message.part.updated',         function(...) events.on_part_updated(make_ctx(), ...) end },
  { 'message.part.removed',         function(...) events.on_part_removed(make_ctx(), ...) end },
  { 'permission.updated',           function(...) events.on_permission_updated(make_ctx(), ...) end },
  { 'permission.asked',             function(...) events.on_permission_updated(make_ctx(), ...) end },
  { 'permission.replied',           function(...) events.on_permission_replied(make_ctx(), ...) end },
  { 'question.asked',               function(...) events.on_question_asked(make_ctx(), ...) end },
  { 'question.replied',             on_question_replied },
  { 'question.rejected',            on_question_replied },
  { 'file.edited',                  function(...) events.on_file_edited(make_ctx(), ...) end },
  { 'custom.restore_point.created', function(...) events.on_restore_points(make_ctx(), ...) end },
  { 'custom.emit_events.finished',  on_emit_events_finished },
}

-- ─── Reset / teardown ─────────────────────────────────────────────────────────

---Reset all renderer state and clear the output buffer.
function M.reset()
  M._prev_line_count = 0
  M._render_state:reset()
  M._last_formatted = { part_id = nil, formatted_data = nil }

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

---Unsubscribe from all events and reset state.
function M.teardown()
  M.setup_subscriptions(false)
  M.reset()
end

-- ─── Event subscriptions ──────────────────────────────────────────────────────

---Register or unregister all event subscriptions.
---@param subscribe? boolean false to unsubscribe (default: true)
function M.setup_subscriptions(subscribe)
  subscribe = subscribe == nil and true or subscribe

  if subscribe then
    state.store.subscribe('is_opencode_focused', on_focus_changed)
    state.store.subscribe('active_session', M.on_session_changed)
  else
    state.store.unsubscribe('is_opencode_focused', on_focus_changed)
    state.store.unsubscribe('active_session', M.on_session_changed)
  end

  if not state.event_manager then
    return
  end

  for _, sub in ipairs(event_subs) do
    if subscribe then
      state.event_manager:subscribe(sub[1], sub[2])
    else
      state.event_manager:unsubscribe(sub[1], sub[2])
    end
  end
end

-- ─── Session rendering ────────────────────────────────────────────────────────

---Fetch full session messages from the server.
---@return Promise<OpencodeMessage[]>
local function fetch_session()
  local session = state.active_session
  if not session or session == '' then
    return Promise.new():resolve(nil)
  end
  state.renderer.set_last_user_message(nil)
  return require('opencode.session').get_messages(session)
end

---Request all session data and render it.
---@return Promise<OpencodeMessage[]>
function M.render_full_session()
  if not output_window.mounted() or not state.api_client then
    return Promise.new():resolve(nil)
  end
  return fetch_session():and_then(M._render_full_session_data)
end

---Re-render an entire session from a list of messages (used after reset or revert).
---@param session_data OpencodeMessage[]
function M._render_full_session_data(session_data)
  M.reset()

  if not state.active_session or not state.messages then
    return
  end

  local revert_index = nil
  local set_model_from_messages = not state.current_model

  local ctx = make_ctx()

  for i, msg in ipairs(session_data) do
    if state.active_session.revert and state.active_session.revert.messageID == msg.info.id then
      revert_index = i
    end

    events.on_message_updated(ctx, { info = msg.info }, revert_index)

    for _, part in ipairs(msg.parts or {}) do
      events.on_part_updated(ctx, { part = part }, revert_index)
    end
  end

  if revert_index then
    buf.write(M._render_state, formatter._format_revert_message(state.messages, revert_index))
  end

  if set_model_from_messages then
    M._set_model_from_messages()
  end

  M.scroll_to_bottom(true)

  if config.hooks and config.hooks.on_session_loaded then
    pcall(config.hooks.on_session_loaded, state.active_session)
  end
end

-- ─── Permission / question display helpers ────────────────────────────────────

---Render all pending permissions as a synthetic buffer entry.
function M.render_permissions_display()
  local permissions = permission_window.get_all_permissions()
  if not permissions or #permissions == 0 then
    buf.remove_part(M._render_state, 'permission-display-part')
    buf.remove_message(M._render_state, 'permission-display-message')
    return
  end

  local fake_message = {
    info = {
      id = 'permission-display-message',
      sessionID = state.active_session and state.active_session.id or '',
      role = 'system',
    },
    parts = {},
  }
  events.on_message_updated(make_ctx(), fake_message --[[@as OpencodeMessage]])

  events.on_part_updated(make_ctx(), {
    part = {
      id = 'permission-display-part',
      messageID = 'permission-display-message',
      sessionID = state.active_session and state.active_session.id or '',
      type = 'permissions-display',
    },
  })
  M.scroll_to_bottom(true)
end

---Clear the question display from the buffer.
function M.clear_question_display()
  local question_window = require('opencode.ui.question_window')

  if config.ui.questions and config.ui.questions.use_vim_ui_select then
    question_window.clear_question()
    return
  end

  question_window.clear_question()
  buf.remove_part(M._render_state, 'question-display-part')
  buf.remove_message(M._render_state, 'question-display-message')
end

---Render the current question as a synthetic buffer entry.
function M.render_question_display()
  if config.ui.questions and config.ui.questions.use_vim_ui_select then
    return
  end

  local question_window = require('opencode.ui.question_window')
  local current_question = question_window._current_question

  if not question_window.has_question() or not current_question or not current_question.id then
    buf.remove_part(M._render_state, 'question-display-part')
    buf.remove_message(M._render_state, 'question-display-message')
    return
  end

  local message_id = 'question-display-message'
  local part_id = 'question-display-part'

  events.on_message_updated(make_ctx(), {
    info = {
      id = message_id,
      sessionID = state.active_session and state.active_session.id or '',
      role = 'system',
    },
    parts = {},
  } --[[@as OpencodeMessage]])

  events.on_part_updated(make_ctx(), {
    part = {
      id = part_id,
      messageID = message_id,
      sessionID = state.active_session and state.active_session.id or '',
      type = 'questions-display',
    },
  })
  M.scroll_to_bottom(true)
end

-- ─── Simple render helpers ────────────────────────────────────────────────────

---Replace the entire output buffer with the given lines.
---@param lines string[]
function M.render_lines(lines)
  local output = require('opencode.ui.output'):new()
  output.lines = lines
  M.render_output(output)
end

---Replace the entire output buffer with an Output object.
---@param output_data Output
function M.render_output(output_data)
  if not output_window.buffer_valid() then
    return
  end
  output_window.set_lines(output_data.lines or {})
  output_window.clear_extmarks()
  output_window.set_extmarks(output_data.extmarks)
  trigger_on_data_rendered()
  M.scroll_to_bottom()
end

-- ─── Scroll ───────────────────────────────────────────────────────────────────

---Scroll the output window to the bottom when appropriate.
---
---Scrolls if: `force` is true, first render, `always_scroll_to_bottom` config
---is set, or the cursor was already at the bottom before the update.
---
---@param force? boolean Always scroll regardless of cursor position.
function M.scroll_to_bottom(force)
  if not output_window.mounted() then
    return
  end

  local windows = state.windows
  local output_win = windows.output_win
  local output_buf = windows.output_buf

  local ok, line_count = pcall(vim.api.nvim_buf_line_count, output_buf)
  if not ok or line_count == 0 then
    return
  end

  local prev = M._prev_line_count or 0
  M._prev_line_count = line_count

  local should_scroll = force
    or prev == 0
    or config.ui.output.always_scroll_to_bottom
    or (function()
      local ok2, cursor = pcall(vim.api.nvim_win_get_cursor, output_win)
      return ok2 and cursor and (cursor[1] >= prev or cursor[1] >= line_count)
    end)()

  if should_scroll then
    vim.api.nvim_win_set_cursor(output_win, { line_count, 0 })
    vim.api.nvim_win_call(output_win, function()
      vim.cmd('normal! zb')
    end)
  end
end

-- ─── Model helpers ────────────────────────────────────────────────────────────

---Set the current model/mode from the most recent assistant message.
function M._set_model_from_messages()
  if not state.messages then
    return
  end
  for i = #state.messages, 1, -1 do
    local msg = state.messages[i]
    if msg and msg.info and msg.info.modelID and msg.info.providerID then
      state.model.set_model(msg.info.providerID .. '/' .. msg.info.modelID)
      if msg.info.mode then
        state.model.set_mode(msg.info.mode)
      end
      return
    end
  end
  require('opencode.core').initialize_current_model()
end

-- ─── Private helpers (exposed for testing) ────────────────────────────────────

---Add a message header to the buffer and update render state.
---Exposed as `_add_message_to_buffer` to keep backward-compat with tests.
---@param message OpencodeMessage
function M._add_message_to_buffer(message)
  buf.add_message(M._render_state, formatter, message)
  if message.info.role == 'user' then
    M.scroll_to_bottom(true)
  end
end

-- ─── Public query API ─────────────────────────────────────────────────────────

---Return all actions available at a buffer line (0-indexed).
---@param line integer
---@return table[]
function M.get_actions_for_line(line)
  return M._render_state:get_actions_at_line(line)
end

---Return the rendered message for `message_id`, or nil.
---@param message_id string
---@return RenderedMessage|nil
function M.get_rendered_message(message_id)
  return M._render_state:get_message(message_id)
end

function M.on_session_changed(_, new, old)
  if (old and old.id) == (new and new.id) then
    return
  end
  M.reset()
  if new then
    M.render_full_session()
  end
end

return M
