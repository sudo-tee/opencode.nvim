local state = require('opencode.state')
local formatter = require('opencode.ui.formatter')
local output_window = require('opencode.ui.output_window')
local Promise = require('opencode.promise')
local MessageMap = require('opencode.ui.message_map')

local M = {}

M._subscriptions = {}
M._part_cache = {}
M._prev_line_count = 0
M._message_map = MessageMap.new()
M._actions = {}

---Reset renderer state
function M.reset()
  M._part_cache = {}
  M._prev_line_count = 0
  M._message_map:reset()
  M._actions = {}

  output_window.clear()

  state.messages = {}
  state.last_user_message = nil
end

---Set up all subscriptions, for both local and server events
function M.setup_subscriptions(_)
  M._subscriptions.active_session = function(_, _, old)
    if not old then
      return
    end
    M.render_full_session()
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

  state.event_manager[method](state.event_manager, 'message.updated', M.on_message_updated)
  state.event_manager[method](state.event_manager, 'message.part.updated', M.on_part_updated)
  state.event_manager[method](state.event_manager, 'message.removed', M.on_message_removed)
  state.event_manager[method](state.event_manager, 'message.part.removed', M.on_part_removed)
  state.event_manager[method](state.event_manager, 'session.compacted', M.on_session_compacted)
  state.event_manager[method](state.event_manager, 'session.error', M.on_session_error)
  state.event_manager[method](state.event_manager, 'permission.updated', M.on_permission_updated)
  state.event_manager[method](state.event_manager, 'permission.replied', M.on_permission_replied)
  state.event_manager[method](state.event_manager, 'file.edited', M.on_file_edited)
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

local function fetch_session()
  local session = state.active_session
  if not state.active_session or not session or session == '' then
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

  state.messages = session_data
  M._message_map:hydrate(state.messages)

  local output_data = formatter._format_messages(state.active_session)

  M.write_output(output_data)
  M._scroll_to_bottom()
end

---Shift cached part and action line positions by delta starting from from_line
---Uses state.messages rather than M._part_cache so it can
---stop early
---@param from_line integer Line number to start shifting from
---@param delta integer Number of lines to shift (positive or negative)
function M._shift_parts_and_actions(from_line, delta)
  if delta == 0 then
    return
  end

  local examined = 0
  local shifted = 0

  for i = #state.messages, 1, -1 do
    local msg_wrapper = state.messages[i]
    if msg_wrapper.parts then
      for j = #msg_wrapper.parts, 1, -1 do
        local part = msg_wrapper.parts[j]
        if part.id then
          local part_data = M._part_cache[part.id]
          if part_data and part_data.line_start then
            examined = examined + 1
            if part_data.line_start < from_line then
              -- vim.notify('Shifting lines from: ' .. from_line .. ' by delta: ' .. delta .. ' examined: ' .. examined .. ' shifted: ' .. shifted)
              return
            end
            part_data.line_start = part_data.line_start + delta
            if part_data.line_end then
              part_data.line_end = part_data.line_end + delta
            end
            shifted = shifted + 1
          end
        end
      end
    end
  end

  -- Shift actions
  for _, action in ipairs(M._actions) do
    if action.display_line and action.display_line >= from_line then
      action.display_line = action.display_line + delta
    end
    if action.range then
      if action.range.from >= from_line then
        action.range.from = action.range.from + delta
      end
      if action.range.to >= from_line then
        action.range.to = action.range.to + delta
      end
    end
  end

  -- vim.notify('Shifting lines from: ' .. from_line .. ' by delta: ' .. delta .. ' examined: ' .. examined .. ' shifted: ' .. shifted)
end

---Sets the entire output buffer based on output_data
---@param output_data Output Output object from formatter
function M.write_output(output_data)
  if not output_window.mounted() then
    return
  end

  -- Extract and store actions with absolute positions
  M._actions = {}
  for _, action in ipairs(output_data.actions or {}) do
    table.insert(M._actions, action)
  end

  output_window.set_lines(output_data.lines)
  output_window.clear_extmarks()
  output_window.set_extmarks(output_data.extmarks)
end

---Auto-scroll to bottom if user was already at bottom
---Respects cursor position if user has scrolled up
function M._scroll_to_bottom()
  local ok, line_count = pcall(vim.api.nvim_buf_line_count, state.windows.output_buf)
  if not ok then
    return
  end

  local botline = vim.fn.line('w$', state.windows.output_win)
  local cursor = vim.api.nvim_win_get_cursor(state.windows.output_win)
  local cursor_row = cursor[1] or 0
  local is_focused = vim.api.nvim_get_current_win() == state.windows.output_win

  local prev_line_count = M._prev_line_count or 0
  M._prev_line_count = line_count

  local was_at_bottom = (botline >= prev_line_count) or prev_line_count == 0

  if is_focused and cursor_row < prev_line_count - 1 then
    return
  end

  if was_at_bottom or not is_focused then
    require('opencode.ui.ui').scroll_to_bottom()
  end
end

---Write data to output_buf, including normal text and extmarks
---@param formatted_data Output Formatted data as Output object
---@return {line_start: integer, line_end: integer}? Range where data was written
function M._write_formatted_data(formatted_data)
  local buf = state.windows.output_buf
  local start_line = output_window.get_buf_line_count()
  local new_lines = formatted_data.lines
  local extmarks = formatted_data.extmarks

  if #new_lines == 0 or not buf then
    return nil
  end

  -- Extract and store actions if present, adjusting to absolute positions
  if formatted_data.actions then
    for _, action in ipairs(formatted_data.actions) do
      action.display_line = action.display_line + start_line
      if action.range then
        action.range.from = action.range.from + start_line
        action.range.to = action.range.to + start_line
      end
      table.insert(M._actions, action)
    end
  end

  output_window.set_lines(new_lines, start_line)
  output_window.set_extmarks(extmarks, start_line)

  return {
    line_start = start_line,
    line_end = start_line + #new_lines - 1,
  }
end

---Write message header to buffer
---@param message OpencodeMessage Message object
---@param msg_idx integer Message index
---@return {line_start: integer, line_end: integer}? Range where header was written
function M._write_message_header(message, msg_idx)
  state.current_message = message
  local header_data = formatter.format_message_header_isolated(message, msg_idx)
  local line_range = M._write_formatted_data(header_data)
  return line_range
end

---Insert new part at end of buffer
---@param part_id string Part ID
---@param formatted_data Output Formatted data as Output object
---@return boolean Success status
function M._insert_part_to_buffer(part_id, formatted_data)
  local cached = M._part_cache[part_id]
  if not cached then
    return false
  end

  if #formatted_data.lines == 0 then
    return true
  end

  local range = M._write_formatted_data(formatted_data)
  if not range then
    return false
  end

  cached.line_start = range.line_start
  cached.line_end = range.line_end
  return true
end

---Replace existing part in buffer
---Adjusts line positions of subsequent parts if line count changes
---@param part_id string Part ID
---@param formatted_data Output Formatted data as Output object
---@return boolean Success status
function M._replace_part_in_buffer(part_id, formatted_data)
  local cached = M._part_cache[part_id]
  if not cached or not cached.line_start or not cached.line_end then
    return false
  end

  local new_lines = formatted_data.lines

  local old_line_count = cached.line_end - cached.line_start + 1
  local new_line_count = #new_lines

  -- Remove actions within the old range
  for i = #M._actions, 1, -1 do
    local action = M._actions[i]
    if action.range and action.range.from >= cached.line_start and action.range.to <= cached.line_end then
      table.remove(M._actions, i)
    end
  end

  -- clear previous extmarks
  output_window.clear_extmarks(cached.line_start, cached.line_end + 1)

  output_window.set_lines(new_lines, cached.line_start, cached.line_end + 1)

  cached.line_end = cached.line_start + new_line_count - 1

  output_window.set_extmarks(formatted_data.extmarks, cached.line_start)

  -- Add new actions if present
  if formatted_data.actions then
    for _, action in ipairs(formatted_data.actions) do
      action.display_line = action.display_line + cached.line_start
      if action.range then
        action.range.from = action.range.from + cached.line_start
        action.range.to = action.range.to + cached.line_start
      end
      table.insert(M._actions, action)
    end
  end

  local line_delta = new_line_count - old_line_count
  if line_delta ~= 0 then
    M._shift_parts_and_actions(cached.line_end + 1, line_delta)
  end

  return true
end

---Remove part from buffer and adjust subsequent line positions
---@param part_id string Part ID
function M._remove_part_from_buffer(part_id)
  local cached = M._part_cache[part_id]
  if not cached or not cached.line_start or not cached.line_end then
    return
  end

  if not state.windows or not state.windows.output_buf then
    return
  end

  local line_count = cached.line_end - cached.line_start + 1

  output_window.set_lines({}, cached.line_start, cached.line_end + 1)

  M._shift_parts_and_actions(cached.line_end + 1, -line_count)
  M._part_cache[part_id] = nil
end

---Event handler for message.updated events
---Creates new message or updates existing message info
---@param event EventMessageUpdated Event object
function M.on_message_updated(event)
  if not event or not event.properties or not event.properties.info then
    return
  end

  ---@type OpencodeMessage
  local message = event.properties
  if not message.info.id or not message.info.sessionID then
    return
  end

  if state.active_session.id ~= message.info.sessionID then
    vim.notify('Session id does not match, discarding message: ' .. vim.inspect(message), vim.log.levels.WARN)
    return
  end

  local found_idx = M._message_map:get_message_index(message.info.id)

  if found_idx then
    state.messages[found_idx].info = message.info
  else
    table.insert(state.messages, message)
    found_idx = #state.messages
    M._message_map:add_message(message.info.id, found_idx)

    M._write_message_header(message, found_idx)
    if message.info.role == 'user' then
      state.last_user_message = message
    end
  end

  M._scroll_to_bottom()
end

---Event handler for message.part.updated events
---Inserts new parts or replaces existing parts in buffer
---@param event EventMessagePartUpdated Event object
function M.on_part_updated(event)
  if not event or not event.properties or not event.properties.part then
    return
  end

  local part = event.properties.part
  if not part.id or not part.messageID or not part.sessionID then
    return
  end

  if state.active_session.id ~= part.sessionID then
    vim.notify('Session id does not match, discarding part: ' .. vim.inspect(part), vim.log.levels.WARN)
    return
  end

  local msg_wrapper, msg_idx = M._message_map:get_message_by_id(part.messageID, state.messages)

  if not msg_wrapper or not msg_idx then
    vim.notify('Could not find message for part: ' .. vim.inspect(part), vim.log.levels.WARN)
    return
  end

  local message = msg_wrapper.info
  msg_wrapper.parts = msg_wrapper.parts or {}

  local is_new_part = not M._message_map:has_part(part.id)
  local part_idx

  if is_new_part then
    table.insert(msg_wrapper.parts, part)
    part_idx = #msg_wrapper.parts
    M._message_map:add_part(part.id, msg_idx, part_idx, part.callID)
  else
    part_idx = M._message_map:update_part(part.id, part, state.messages)
    if not part_idx then
      return
    end
  end

  if part.type == 'step-start' or part.type == 'step-finish' then
    return
  end

  local part_text = part.text or ''

  if not M._part_cache[part.id] then
    M._part_cache[part.id] = {
      text = nil,
      line_start = nil,
      line_end = nil,
      message_id = part.messageID,
      type = part.type,
    }
  end

  local ok, formatted = pcall(formatter.format_part_single, part, {
    msg_idx = msg_idx,
    part_idx = part_idx,
    role = message.role,
    message = msg_wrapper,
  })

  if not ok then
    vim.notify('format_part_single error: ' .. tostring(formatted), vim.log.levels.ERROR)
    return
  end

  if is_new_part then
    M._insert_part_to_buffer(part.id, formatted)
  else
    M._replace_part_in_buffer(part.id, formatted)
  end

  M._part_cache[part.id].text = part_text
  M._scroll_to_bottom()
end

---Event handler for message.part.removed events
---@param event EventMessagePartRemoved Event object
function M.on_part_removed(event)
  if not event or not event.properties then
    return
  end

  local part_id = event.properties.partID
  if not part_id then
    return
  end

  local cached = M._part_cache[part_id]
  if cached and cached.message_id then
    local part = M._message_map:get_part_by_id(part_id, state.messages)
    local call_id = part and part.callID or nil
    M._message_map:remove_part(part_id, call_id, state.messages)
  end

  M._remove_part_from_buffer(part_id)
end

---Event handler for message.removed events
---Removes message and all its parts from buffer
---@param event EventMessageRemoved Event object
function M.on_message_removed(event)
  if not event or not event.properties then
    return
  end

  local message_id = event.properties.messageID
  if not message_id then
    return
  end

  local message_idx = M._message_map:get_message_index(message_id)
  if not message_idx then
    return
  end

  local msg_wrapper = state.messages[message_idx]
  for _, part in ipairs(msg_wrapper.parts or {}) do
    if part.id then
      M._remove_part_from_buffer(part.id)
    end
  end

  M._message_map:remove_message(message_id, state.messages)
end

---Event handler for session.compacted events
---@param event EventSessionCompacted Event object
function M.on_session_compacted(event)
  vim.notify('on_session_compacted')
  -- TODO: render a note that the session was compacted
  -- FIXME: did we need unset state.last_sent_context because the
  -- session was compacted?
end

---Event handler for session.error events
---@param event EventSessionError Event object
function M.on_session_error(event)
  if not event or not event.properties or not event.properties.error then
    return
  end

  local error_data = event.properties.error
  local error_message = error_data.data and error_data.data.message or vim.inspect(error_data)

  local formatted = formatter.format_error_callout(error_message)

  M._write_formatted_data(formatted)
  M._scroll_to_bottom()
end

---Event handler for permission.updated events
---Re-renders part that requires permission
---@param event EventPermissionUpdated Event object
function M.on_permission_updated(event)
  if not event or not event.properties then
    return
  end

  local permission = event.properties
  if not permission.messageID or not permission.callID then
    return
  end

  state.current_permission = permission

  local part_id = M._find_part_by_call_id(permission.callID)
  if part_id then
    M._rerender_part(part_id)
    M._scroll_to_bottom()
  end
end

---Event handler for permission.replied events
---Re-renders part after permission is resolved
---@param event EventPermissionReplied Event object
function M.on_permission_replied(event)
  if not event or not event.properties then
    return
  end

  local old_permission = state.current_permission
  state.current_permission = nil

  if old_permission and old_permission.callID then
    local part_id = M._find_part_by_call_id(old_permission.callID)
    if part_id then
      M._rerender_part(part_id)
      M._scroll_to_bottom()
    end
  end
end

function M.on_file_edited(event)
  vim.cmd('checktime')
end

---Find part ID by call ID
---Searches messages in reverse order for efficiency
---Useful for finding a part for a permission
---@param call_id string Call ID to search for
---@return string? part_id Part ID if found, nil otherwise
function M._find_part_by_call_id(call_id)
  return M._message_map:get_part_id_by_call_id(call_id)
end

---Re-render existing part with current state
---Used for permission updates and other dynamic changes
---@param part_id string Part ID to re-render
function M._rerender_part(part_id)
  local cached = M._part_cache[part_id]
  if not cached then
    return
  end

  local part, msg_wrapper, msg_idx, part_idx = M._message_map:get_part_by_id(part_id, state.messages)

  if not part or not msg_wrapper then
    return
  end

  local message_with_parts = vim.tbl_extend('force', msg_wrapper.info, { parts = msg_wrapper.parts })
  local ok, formatted = pcall(formatter.format_part_single, part, {
    msg_idx = msg_idx or 1,
    part_idx = part_idx or 1,
    role = msg_wrapper.info.role,
    message = message_with_parts,
  })

  if not ok then
    vim.notify('format_part_single error: ' .. tostring(formatted), vim.log.levels.ERROR)
    return
  end

  M._replace_part_in_buffer(part_id, formatted)
end

---Get all actions available at a specific line
---@param line number 1-indexed line number
---@return table[] List of actions available at that line
function M.get_actions_for_line(line)
  local actions = {}
  for _, action in ipairs(M._actions) do
    if action.range and action.range.from <= line and action.range.to >= line then
      table.insert(actions, action)
    end
  end
  return actions
end

return M
