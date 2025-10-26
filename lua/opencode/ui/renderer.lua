local state = require('opencode.state')
local config = require('opencode.config')
local formatter = require('opencode.ui.formatter')
local output_window = require('opencode.ui.output_window')
local Promise = require('opencode.promise')
local RenderState = require('opencode.ui.render_state')

local M = {}

M._subscriptions = {}
M._prev_line_count = 0
M._render_state = RenderState.new()
M._last_part_formatted = {
  part_id = nil,
  formatted_data = nil --[[@as Output|nil]],
}

local trigger_on_data_rendered = require('opencode.util').debounce(function()
  local cb_type = type(config.ui.output.rendering.on_data_rendered)

  if cb_type == 'boolean' then
    return
  end

  if not state.windows then
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

---Reset renderer state
function M.reset()
  M._prev_line_count = 0
  M._render_state:reset()
  M._last_part_formatted = { part_id = nil, formatted_data = nil }

  output_window.clear()

  state.messages = {}
  state.last_user_message = nil
  state.current_permission = nil
  trigger_on_data_rendered()
end

---Set up all subscriptions, for both local and server events
function M.setup_subscriptions(_)
  M._subscriptions.active_session = function(_, new, _)
    M.reset()
    if new then
      M.render_full_session()
    end
  end
  state.subscribe('active_session', M._subscriptions.active_session)
  M._setup_event_subscriptions()
end

---Set up server event subscriptions
---@param subscribe? boolean false to unsubscribe
function M._setup_event_subscriptions(subscribe)
  if not state.event_manager then
    return
  end

  local method = (subscribe == false) and 'unsubscribe' or 'subscribe'

  state.event_manager[method](state.event_manager, 'session.updated', M.on_session_updated)
  state.event_manager[method](state.event_manager, 'session.compacted', M.on_session_compacted)
  state.event_manager[method](state.event_manager, 'session.error', M.on_session_error)
  state.event_manager[method](state.event_manager, 'message.updated', M.on_message_updated)
  state.event_manager[method](state.event_manager, 'message.removed', M.on_message_removed)
  state.event_manager[method](state.event_manager, 'message.part.updated', M.on_part_updated)
  state.event_manager[method](state.event_manager, 'message.part.removed', M.on_part_removed)
  state.event_manager[method](state.event_manager, 'permission.updated', M.on_permission_updated)
  state.event_manager[method](state.event_manager, 'permission.replied', M.on_permission_replied)
  state.event_manager[method](state.event_manager, 'file.edited', M.on_file_edited)
  state.event_manager[method](state.event_manager, 'custom.restore_point.created', M.on_restore_points)
  state.event_manager[method](state.event_manager, 'custom.emit_events.finished', M.on_emit_events_finished)

  state[method]('is_opencode_focused', M.on_focus_changed)
end

---Unsubscribe from local state and server subscriptions
function M._cleanup_subscriptions()
  M._setup_event_subscriptions(false)
  for key, cb in pairs(M._subscriptions) do
    state.unsubscribe(key, cb)
  end
  M._subscriptions = {}
end

---Clean up and teardown renderer. Unsubscribes from all
---events, local state and server
function M.teardown()
  M._cleanup_subscriptions()
  M.reset()
end

---Fetch full session messages from server
---@return Promise<OpencodeMessage[]> Promise resolving to list of OpencodeMessage
local function fetch_session()
  local session = state.active_session
  if not session or not session or session == '' then
    return Promise.new():resolve(nil)
  end

  state.last_user_message = nil
  return require('opencode.session').get_messages(session)
end

function M.render_full_session()
  if not output_window.mounted() or not state.api_client then
    return
  end

  fetch_session():and_then(M._render_full_session_data)
end

function M._render_full_session_data(session_data)
  M.reset()

  if not state.active_session or not state.messages then
    return
  end

  local revert_index = nil

  -- local event_manager = state.event_manager

  for i, msg in ipairs(session_data) do
    if state.active_session.revert and state.active_session.revert.messageID == msg.info.id then
      revert_index = i
    end

    -- table.insert(event_manager.captured_events, { type = 'message.updated', properties = { info = msg.info } })
    M.on_message_updated({ info = msg.info }, revert_index)

    for _, part in ipairs(msg.parts or {}) do
      -- table.insert(event_manager.captured_events, { type = 'message.part.updated', properties = { part = part } })
      M.on_part_updated({ part = part }, revert_index)
    end
  end

  if revert_index then
    M._write_formatted_data(formatter._format_revert_message(state.messages, revert_index))
  end

  M.scroll_to_bottom()
end

---Render lines as the entire output buffer
---@param lines any
function M.render_lines(lines)
  local output = require('opencode.ui.output'):new()
  output.lines = lines
  M.render_output(output)
end

---Sets the entire output buffer based on output_data
---@param output_data Output Output object from formatter
function M.render_output(output_data)
  if not output_window.mounted() then
    return
  end

  output_window.set_lines(output_data.lines)
  output_window.clear_extmarks()
  output_window.set_extmarks(output_data.extmarks)
  M.scroll_to_bottom()
end

---Called when EventManager has finished emitting a batch of events
function M.on_emit_events_finished()
  M.scroll_to_bottom()
end

---Auto-scroll to bottom if user was already at bottom
---Respects cursor position if user has scrolled up
function M.scroll_to_bottom()
  if not state.windows or not state.windows.output_buf or not state.windows.output_win then
    return
  end

  local ok, line_count = pcall(vim.api.nvim_buf_line_count, state.windows.output_buf)
  if not ok then
    return
  end

  local botline = vim.fn.line('w$', state.windows.output_win)
  local cursor = vim.api.nvim_win_get_cursor(state.windows.output_win)
  local cursor_row = cursor[1] or 0
  local is_focused = vim.api.nvim_get_current_win() == state.windows.output_win

  local prev_line_count = M._prev_line_count or 0

  ---@cast line_count integer
  M._prev_line_count = line_count

  local was_at_bottom = (botline >= prev_line_count) or prev_line_count == 0

  trigger_on_data_rendered()

  if is_focused and cursor_row < prev_line_count - 1 then
    return
  end

  if was_at_bottom or not is_focused then
    vim.api.nvim_win_set_cursor(state.windows.output_win, { line_count, 0 })
  end
end

---Write data to output_buf, including normal text and extmarks
---@param formatted_data Output Formatted data as Output object
---@param part_id? string Optional part ID to store actions
---@return {line_start: integer, line_end: integer}? Range where data was written
function M._write_formatted_data(formatted_data, part_id)
  if not state.windows or not state.windows.output_buf then
    return
  end

  local buf = state.windows.output_buf
  local start_line = output_window.get_buf_line_count()
  local new_lines = formatted_data.lines
  local extmarks = formatted_data.extmarks

  if #new_lines == 0 or not buf then
    return nil
  end

  if part_id and formatted_data.actions then
    M._render_state:add_actions(part_id, formatted_data.actions, start_line)
  end

  output_window.set_lines(new_lines, start_line)
  output_window.set_extmarks(extmarks, start_line)

  return {
    line_start = start_line,
    line_end = start_line + #new_lines - 1,
  }
end

---Insert new part at end of buffer
---@param part_id string Part ID
---@param formatted_data Output Formatted data as Output object
---@return boolean Success status
function M._insert_part_to_buffer(part_id, formatted_data)
  local cached = M._render_state:get_part(part_id)
  if not cached then
    return false
  end

  if #formatted_data.lines == 0 then
    return true
  end

  local range = M._write_formatted_data(formatted_data, part_id)
  if not range then
    return false
  end

  M._render_state:set_part(cached.part, range.line_start, range.line_end)

  M._last_part_formatted = { part_id = part_id, formatted_data = formatted_data }

  return true
end

---Replace existing part in buffer
---Adjusts line positions of subsequent parts if line count changes
---@param part_id string Part ID
---@param formatted_data Output Formatted data as Output object
---@return boolean Success status
function M._replace_part_in_buffer(part_id, formatted_data)
  local cached = M._render_state:get_part(part_id)
  if not cached or not cached.line_start or not cached.line_end then
    return false
  end

  local new_lines = formatted_data.lines
  local new_line_count = #new_lines
  -- local old_line_count = cached.line_end - cached.line_start + 1

  local old_formatted = M._last_part_formatted
  local can_optimize = old_formatted
    and old_formatted.part_id == part_id
    and old_formatted.formatted_data
    and old_formatted.formatted_data.lines

  local lines_to_write = new_lines
  local write_start_line = cached.line_start

  if can_optimize then
    ---@cast old_formatted { formatted_data: { lines: string[] } }
    local old_lines = old_formatted.formatted_data.lines
    local first_diff_line = nil

    for i = 1, math.min(#old_lines, new_line_count) do
      if old_lines[i] ~= new_lines[i] then
        first_diff_line = i
        break
      end
    end

    if not first_diff_line and new_line_count > #old_lines then
      first_diff_line = #old_lines + 1
    end

    if first_diff_line then
      lines_to_write = vim.list_slice(new_lines, first_diff_line, new_line_count)
      write_start_line = cached.line_start + first_diff_line - 1
    elseif new_line_count == #old_lines then
      M._last_part_formatted = { part_id = part_id, formatted_data = formatted_data }
      return true
    end
  end

  M._render_state:clear_actions(part_id)

  output_window.clear_extmarks(cached.line_start - 1, cached.line_end + 1)
  output_window.set_lines(lines_to_write, write_start_line, cached.line_end + 1)

  local new_line_end = cached.line_start + new_line_count - 1

  output_window.set_extmarks(formatted_data.extmarks, cached.line_start)

  if formatted_data.actions then
    M._render_state:add_actions(part_id, formatted_data.actions, cached.line_start)
  end

  M._render_state:update_part_lines(part_id, cached.line_start, new_line_end)

  M._last_part_formatted = { part_id = part_id, formatted_data = formatted_data }

  return true
end

---Remove part from buffer and adjust subsequent line positions
---@param part_id string Part ID
function M._remove_part_from_buffer(part_id)
  local cached = M._render_state:get_part(part_id)
  if not cached or not cached.line_start or not cached.line_end then
    return
  end

  if not state.windows or not state.windows.output_buf then
    return
  end

  output_window.clear_extmarks(cached.line_start - 1, cached.line_end)
  output_window.set_lines({}, cached.line_start - 1, cached.line_end)

  M._render_state:remove_part(part_id)
end

---Remove message header from buffer and adjust subsequent line positions
---@param message_id string Message ID
function M._remove_message_from_buffer(message_id)
  local cached = M._render_state:get_message(message_id)
  if not cached or not cached.line_start or not cached.line_end then
    return
  end

  if not state.windows or not state.windows.output_buf then
    return
  end

  output_window.clear_extmarks(cached.line_start - 1, cached.line_end)
  output_window.set_lines({}, cached.line_start - 1, cached.line_end)

  M._render_state:remove_message(message_id)
end

---Adds a message (most likely just a header) to the buffer
---@param message OpencodeMessage Message to add
function M._add_message_to_buffer(message)
  local header_data = formatter.format_message_header(message)
  local range = M._write_formatted_data(header_data)

  if range then
    M._render_state:set_message(message, range.line_start, range.line_end)
  end
end

---Replace existing message header in buffer
---@param message_id string Message ID
---@param formatted_data Output Formatted header as Output object
---@return boolean Success status
function M._replace_message_in_buffer(message_id, formatted_data)
  local cached = M._render_state:get_message(message_id)
  if not cached or not cached.line_start or not cached.line_end then
    return false
  end

  local new_lines = formatted_data.lines
  local new_line_count = #new_lines

  output_window.clear_extmarks(cached.line_start, cached.line_end + 1)
  output_window.set_lines(new_lines, cached.line_start, cached.line_end + 1)
  output_window.set_extmarks(formatted_data.extmarks, cached.line_start)

  local old_line_end = cached.line_end
  local new_line_end = cached.line_start + new_line_count - 1

  M._render_state:set_message(cached.message, cached.line_start, new_line_end)

  local delta = new_line_end - old_line_end
  if delta ~= 0 then
    M._render_state:shift_all(old_line_end + 1, delta)
  end

  return true
end

---Event handler for message.updated events
---Creates new message or updates existing message info
---@param message {info: MessageInfo} Event properties
---@param revert_index? integer Revert index in session, if applicable
function M.on_message_updated(message, revert_index)
  if not state.active_session or not state.messages then
    return
  end

  local msg = message --[[@as OpencodeMessage]]
  if not msg or not msg.info or not msg.info.id or not msg.info.sessionID then
    return
  end

  if state.active_session.id ~= msg.info.sessionID then
    ---@TODO This is probably a child session message, handle differently?
    -- vim.notify('Session id does not match, discarding message: ' .. vim.inspect(message), vim.log.levels.WARN)
    return
  end

  local rendered_message = M._render_state:get_message(msg.info.id)
  local found_msg = rendered_message and rendered_message.message

  if revert_index then
    if not found_msg then
      table.insert(state.messages, msg)
    end
    M._render_state:set_message(msg, 0, 0)
    return
  end

  if found_msg then
    -- see if an error was added (or removed). have to check before we set
    -- found_msg.info = message.info below
    local rerender_message = not vim.deep_equal(found_msg.info.error, msg.info.error)

    found_msg.info = msg.info

    if rerender_message and not revert_index then
      local header_data = formatter.format_message_header(found_msg)
      M._replace_message_in_buffer(msg.info.id, header_data)
    end
  else
    table.insert(state.messages, msg)

    M._add_message_to_buffer(msg)

    state.current_message = msg
    if message.info.role == 'user' then
      state.last_user_message = msg
    end
  end

  M._update_stats_from_message(msg)
end

---Event handler for message.part.updated events
---Inserts new parts or replaces existing parts in buffer
---@param properties {part: OpencodeMessagePart} Event properties
---@param revert_index? integer Revert index in session, if applicable
function M.on_part_updated(properties, revert_index)
  if not properties or not properties.part or not state.active_session then
    return
  end

  local part = properties.part
  if not part.id or not part.messageID or not part.sessionID then
    return
  end

  if state.active_session.id ~= part.sessionID then
    ---@TODO This is probably a child session part, handle differently?
    -- vim.notify('Session id does not match, discarding part: ' .. vim.inspect(part), vim.log.levels.WARN)
    return
  end

  local rendered_message = M._render_state:get_message(part.messageID)
  if not rendered_message or not rendered_message.message then
    vim.notify('Could not find message for part: ' .. vim.inspect(part), vim.log.levels.WARN)
    return
  end

  local message = rendered_message.message

  message.parts = message.parts or {}

  local part_data = M._render_state:get_part(part.id)
  local is_new_part = not part_data

  if is_new_part then
    table.insert(message.parts, part)
  else
    for i = #message.parts, 1, -1 do
      if message.parts[i].id == part.id then
        message.parts[i] = part
        break
      end
    end
  end

  if part.type == 'step-start' or part.type == 'step-finish' then
    return
  end

  if is_new_part then
    M._render_state:set_part(part)
  else
    M._render_state:update_part_data(part)
  end

  local formatted = formatter.format_part(part, message)

  if revert_index and is_new_part then
    return
  end

  if is_new_part then
    M._insert_part_to_buffer(part.id, formatted)
  else
    M._replace_part_in_buffer(part.id, formatted)
  end

  if (part.type == 'file' or part.type == 'agent') and part.source then
    -- we have a mention, we need to rerender the early part to highlight
    -- the mention.
    local text_part_id = M._find_text_part_for_message(message)
    if text_part_id then
      M._rerender_part(text_part_id)
    end
  end
end

---Event handler for message.part.removed events
---@param properties {sessionID: string, messageID: string, partID: string} Event properties
function M.on_part_removed(properties)
  if not properties then
    return
  end

  local part_id = properties.partID
  if not part_id then
    return
  end

  local cached = M._render_state:get_part(part_id)
  if cached and cached.message_id then
    local rendered_message = M._render_state:get_message(cached.message_id)
    if rendered_message and rendered_message.message then
      local message = rendered_message.message
      if message.parts then
        for i, part in ipairs(message.parts) do
          if part.id == part_id then
            table.remove(message.parts, i)
            break
          end
        end
      end
    end
  end

  M._remove_part_from_buffer(part_id)
end

---Event handler for message.removed events
---Removes message and all its parts from buffer
---@param properties {sessionID: string, messageID: string} Event properties
function M.on_message_removed(properties)
  if not properties or not state.messages then
    return
  end

  local message_id = properties.messageID
  if not message_id then
    return
  end

  local rendered_message = M._render_state:get_message(message_id)
  if not rendered_message or not rendered_message.message then
    return
  end

  local message = rendered_message.message
  for _, part in ipairs(message.parts or {}) do
    if part.id then
      M._remove_part_from_buffer(part.id)
    end
  end

  M._remove_message_from_buffer(message_id)

  for i, msg in ipairs(state.messages or {}) do
    if msg.info.id == message_id then
      table.remove(state.messages, i)
      break
    end
  end
end

---Event handler for session.compacted events
---@param properties {sessionID: string} Event properties
function M.on_session_compacted(properties)
  vim.notify('on_session_compacted')
  -- TODO: render a note that the session was compacted
  -- FIXME: did we need unset state.last_sent_context because the
  -- session was compacted?
end

---Event handler for session.updated events
---@param properties {info: Session}
function M.on_session_updated(properties)
  if not properties or not properties.info or not state.active_session then
    return
  end
  require('opencode.ui.topbar').render()
  if not vim.deep_equal(state.active_session.revert, properties.info.revert) then
    state.active_session.revert = properties.info.revert
    M._render_full_session_data(state.messages)
  end
end

---Event handler for session.error events
---@param properties {sessionID: string, error: table} Event properties
function M.on_session_error(properties)
  if not properties or not properties.error then
    return
  end

  -- NOTE: we're handling message errors so session errors seem duplicative

  if config.debug.enabled then
    vim.notify('Session error: ' .. vim.inspect(properties.error))
  end
end

---Event handler for permission.updated events
---Re-renders part that requires permission
---@param permission OpencodePermission Event properties
function M.on_permission_updated(permission)
  if not permission or not permission.messageID or not permission.callID then
    return
  end

  if state.current_permission and state.current_permission.id ~= permission.id then
    -- we got a permission request while we had an existing one?
    vim.notify('Two pending permissions? existing: ' .. state.current_permission.id .. ' new: ' .. permission.id)

    -- This will rerender the part with the old permission
    M.on_permission_replied({})
  end

  state.current_permission = permission

  local part_id = M._find_part_by_call_id(permission.callID, permission.messageID)
  if part_id then
    M._rerender_part(part_id)
  end
end

---Event handler for permission.replied events
---Re-renders part after permission is resolved
---@param properties {sessionID: string, permissionID: string, response: string}|{} Event properties
function M.on_permission_replied(properties)
  if not properties then
    return
  end

  local old_permission = state.current_permission
  state.current_permission = nil

  if old_permission and old_permission.callID then
    local part_id = M._find_part_by_call_id(old_permission.callID, old_permission.messageID)
    if part_id then
      M._rerender_part(part_id)
    end
  end
end

function M.on_file_edited(_)
  vim.cmd('checktime')
end

---@param properties RestorePointCreatedEvent
function M.on_restore_points(properties)
  state.append('restore_points', properties.restore_point)
  if not properties or not properties.restore_point or not properties.restore_point.from_snapshot_id then
    return
  end
  local part = M._render_state:get_part_by_snapshot_id(properties.restore_point.from_snapshot_id)
  if part then
    M.on_part_updated({ part = part })
  end
end

---Find part ID by call ID and message ID
---Useful for finding a part for a permission
---@param call_id string Call ID to search for
---@param message_id string Message ID to check the parts of
---@return string? part_id Part ID if found, nil otherwise
function M._find_part_by_call_id(call_id, message_id)
  return M._render_state:get_part_by_call_id(call_id, message_id)
end

---Find the text part in a message
---@param message OpencodeMessage The message containing the parts
---@return string? text_part_id The ID of the text part
function M._find_text_part_for_message(message)
  if not message or not message.parts then
    return nil
  end

  for _, part in ipairs(message.parts) do
    if part.type == 'text' and not part.synthetic then
      return part.id
    end
  end

  return nil
end

---Re-render existing part with current state
---Used for permission updates and other dynamic changes
---@param part_id string Part ID to re-render
function M._rerender_part(part_id)
  local cached = M._render_state:get_part(part_id)
  if not cached or not cached.part then
    return
  end

  local part = cached.part
  local rendered_message = M._render_state:get_message(cached.message_id)
  if not rendered_message or not rendered_message.message then
    return
  end

  local message = rendered_message.message
  local formatted = formatter.format_part(part, message)

  M._replace_part_in_buffer(part_id, formatted)
end

---Event handler for focus changes
---Re-renders part associated with current permission for displaying global shortcuts or buffer-local ones
function M.on_focus_changed()
  if not state.current_permission or not state.current_permission.callID then
    return
  end

  local part_id = M._find_part_by_call_id(state.current_permission.callID, state.current_permission.messageID)
  if part_id then
    M._rerender_part(part_id)
    trigger_on_data_rendered()
  end
end

---Get all actions available at a specific line
---@param line integer 1-indexed line number
---@return table[] List of actions available at that line
function M.get_actions_for_line(line)
  return M._render_state:get_actions_at_line(line)
end

---Update stats from all messages in session
---@param messages OpencodeMessage[]
function M._update_stats_from_messages(messages)
  for _, msg in ipairs(messages) do
    M._update_stats_from_message(msg)
  end
end

---Update display stats from a single message
---@param message OpencodeMessage
function M._update_stats_from_message(message)
  if not state.current_model and message.info.providerID and message.info.providerID ~= '' then
    state.current_model = message.info.providerID .. '/' .. message.info.modelID
  end

  local tokens = message.info.tokens
  if tokens and tokens.input > 0 then
    state.tokens_count = tokens.input + tokens.output + tokens.cache.read + tokens.cache.write
  end

  if message.info.cost and type(message.info.cost) == 'number' then
    state.cost = message.info.cost
  end
end

return M
