local state = require('opencode.state')
local config = require('opencode.config')
local formatter = require('opencode.ui.formatter')
local output_window = require('opencode.ui.output_window')
local permission_window = require('opencode.ui.permission_window')
local Promise = require('opencode.promise')
local RenderState = require('opencode.ui.render_state')

local M = {
  _prev_line_count = 0,
  _render_state = RenderState.new(),
  _full_render_in_flight = nil,
  _full_render_pending_opts = nil,
  _last_part_formatted = {
    part_id = nil,
    formatted_data = nil --[[@as Output|nil]],
  },
}

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

---Reset renderer state
function M.reset()
  M._prev_line_count = 0
  M._render_state:reset()
  M._full_render_pending_opts = nil
  M._last_part_formatted = { part_id = nil, formatted_data = nil }

  output_window.clear()

  state.messages = {}
  state.last_user_message = nil
  state.tokens_count = 0

  local permissions = state.pending_permissions or {}
  if #permissions and state.api_client then
    for _, permission in ipairs(permissions) do
      require('opencode.api').permission_deny(permission)
    end
  end
  permission_window.clear_all()
  state.pending_permissions = {}

  trigger_on_data_rendered()
end

---Set up event subscriptions
---@param subscribe? boolean false to unsubscribe
function M.setup_subscriptions(subscribe)
  subscribe = subscribe == nil and true or subscribe

  if subscribe then
    state.subscribe('is_opencode_focused', M.on_focus_changed)
    state.subscribe('active_session', M.on_session_changed)
  else
    state.unsubscribe('is_opencode_focused', M.on_focus_changed)
    state.unsubscribe('active_session', M.on_session_changed)
  end

  if not state.event_manager then
    return
  end

  local event_subscriptions = {
    { 'session.updated', M.on_session_updated },
    { 'session.compacted', M.on_session_compacted },
    { 'session.error', M.on_session_error },
    { 'message.updated', M.on_message_updated },
    { 'message.removed', M.on_message_removed },
    { 'message.part.updated', M.on_part_updated },
    { 'message.part.removed', M.on_part_removed },
    { 'permission.updated', M.on_permission_updated },
    { 'permission.asked', M.on_permission_updated },
    { 'permission.replied', M.on_permission_replied },
    { 'question.asked', M.on_question_asked },
    { 'question.replied', M.clear_question_display },
    { 'question.rejected', M.clear_question_display },
    { 'file.edited', M.on_file_edited },
    { 'custom.restore_point.created', M.on_restore_points },
    { 'custom.emit_events.finished', M.on_emit_events_finished },
  }

  for _, sub in ipairs(event_subscriptions) do
    if subscribe then
      state.event_manager:subscribe(sub[1], sub[2])
    else
      state.event_manager:unsubscribe(sub[1], sub[2])
    end
  end
end

---Clean up and teardown renderer. Unsubscribes from all events
function M.teardown()
  M.setup_subscriptions(false)
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

---@param opts? {force_scroll?: boolean}
---@return Promise<OpencodeMessage[]>
function M.render_full_session(opts)
  opts = opts or {}

  if not output_window.mounted() or not state.api_client then
    return Promise.new():resolve(nil)
  end

  if M._full_render_in_flight then
    M._full_render_pending_opts = M._full_render_pending_opts or {}
    M._full_render_pending_opts.force_scroll = M._full_render_pending_opts.force_scroll
      or (opts.force_scroll == true)
    return M._full_render_in_flight
  end

  local render_promise = fetch_session():and_then(function(session_data)
    return M._render_full_session_data(session_data, opts)
  end)

  M._full_render_in_flight = render_promise

  render_promise:finally(function()
    M._full_render_in_flight = nil

    local pending_opts = M._full_render_pending_opts
    if pending_opts then
      M._full_render_pending_opts = nil
      vim.schedule(function()
        if output_window.mounted() and state.api_client then
          M.render_full_session(pending_opts)
        end
      end)
    end
  end)

  return render_promise
end

---@param session_data table
---@param opts? {force_scroll?: boolean}
function M._render_full_session_data(session_data, opts)
  opts = opts or {}
  session_data = session_data or {}
  M.reset()

  if not state.active_session or not state.messages then
    return
  end

  local revert_index = nil

  -- if we're loading a session and there's no currently selected model, set it
  -- from the messages
  local set_mode_from_messages = not state.current_model

  for i, msg in ipairs(session_data) do
    if state.active_session.revert and state.active_session.revert.messageID == msg.info.id then
      revert_index = i
    end

    M.on_message_updated({ info = msg.info }, revert_index)

    for _, part in ipairs(msg.parts or {}) do
      M.on_part_updated({ part = part }, revert_index)
    end
  end

  if revert_index then
    M._write_formatted_data(formatter._format_revert_message(state.messages, revert_index))
  end

  if set_mode_from_messages then
    M._set_model_and_mode_from_messages()
  end
  M.scroll_to_bottom(opts.force_scroll == true)

  if config.hooks and config.hooks.on_session_loaded then
    pcall(config.hooks.on_session_loaded, state.active_session)
  end
end

---Append permissions display as a fake part at the end
function M.render_permissions_display()
  local permissions = permission_window.get_all_permissions()
  if not permissions or #permissions == 0 then
    M._remove_part_from_buffer('permission-display-part')
    M._remove_message_from_buffer('permission-display-message')
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
  M.on_message_updated(fake_message --[[@as OpencodeMessage]])

  local fake_part = {
    id = 'permission-display-part',
    messageID = 'permission-display-message',
    sessionID = state.active_session and state.active_session.id or '',
    type = 'permissions-display',
  }

  M.on_part_updated({ part = fake_part })
  M.scroll_to_bottom(true)
end

function M.clear_question_display()
  local question_window = require('opencode.ui.question_window')
  question_window.clear_question()
  M._remove_part_from_buffer('question-display-part')
  M._remove_message_from_buffer('question-display-message')
end

---Render question display as a fake part
function M.render_question_display()
  local question_window = require('opencode.ui.question_window')

  local current_question = question_window._current_question

  if not question_window.has_question() or not current_question or not current_question.id then
    M._remove_part_from_buffer('question-display-part')
    M._remove_message_from_buffer('question-display-message')
    return
  end

  local message_id = 'question-display-message'
  local part_id = 'question-display-part'

  local fake_message = {
    info = {
      id = message_id,
      sessionID = state.active_session and state.active_session.id or '',
      role = 'system',
    },
    parts = {},
  }
  M.on_message_updated(fake_message --[[@as OpencodeMessage]])

  local fake_part = {
    id = part_id,
    messageID = message_id,
    sessionID = state.active_session and state.active_session.id or '',
    type = 'questions-display',
  }

  M.on_part_updated({ part = fake_part })
  M.scroll_to_bottom(true)
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

  local lines = output_data.lines or {}

  output_window.set_lines(lines)
  output_window.clear_extmarks()
  output_window.set_extmarks(output_data.extmarks)
  M.scroll_to_bottom()
end

---Called when EventManager has finished emitting a batch of events
function M.on_emit_events_finished()
  M.scroll_to_bottom()
end

---Find the most recently used model from the messages
function M._set_model_and_mode_from_messages()
  if not state.messages then
    return
  end

  for i = #state.messages, 1, -1 do
    local message = state.messages[i]

    if message and message.info then
      if message.info.modelID and message.info.providerID then
        state.current_model = message.info.providerID .. '/' .. message.info.modelID
        if message.info.mode then
          state.current_mode = message.info.mode
        end
        return
      end
    end
  end

  -- we didn't find a model from any messages, set it to the default
  require('opencode.core').initialize_current_model()
end

---Auto-scroll to bottom if user was already at bottom
---Respects cursor position if user has scrolled up
---@param force? boolean If true, scroll regardless of current position
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

  local prev_line_count = M._prev_line_count or 0

  ---@cast line_count integer
  M._prev_line_count = line_count

  trigger_on_data_rendered()

  local scroll_conditions = {
    {
      name = 'force',
      test = function()
        return force == true
      end,
    },
    {
      name = 'first_render',
      test = function()
        return prev_line_count == 0
      end,
    },
    {
      name = 'always_scroll',
      test = function()
        return config.ui.output.always_scroll_to_bottom
      end,
    },
    {
      name = 'cursor_at_bottom',
      test = function()
        local ok_cursor, cursor = pcall(vim.api.nvim_win_get_cursor, output_win)
        return ok_cursor and cursor and (cursor[1] >= prev_line_count or cursor[1] >= line_count)
      end,
    },
  }

  local should_scroll = false
  for _, condition in ipairs(scroll_conditions) do
    if condition.test() then
      should_scroll = true
      break
    end
  end

  if should_scroll then
    vim.api.nvim_win_set_cursor(output_win, { line_count, 0 })
    vim.api.nvim_win_call(output_win, function()
      vim.cmd('normal! zb')
    end)
  end
end

---Write data to output_buf, including normal text and extmarks
---@param formatted_data Output Formatted data as Output object
---@param part_id? string Optional part ID to store actions
---@param start_line? integer Optional line to insert at (shifts content down). If nil, appends to end of buffer.
---@return {line_start: integer, line_end: integer}? Range where data was written
function M._write_formatted_data(formatted_data, part_id, start_line)
  if not state.windows or not state.windows.output_buf then
    return
  end

  local buf = state.windows.output_buf
  local is_insertion = start_line ~= nil
  local target_line = start_line or output_window.get_buf_line_count()
  local new_lines = formatted_data.lines
  local extmarks = formatted_data.extmarks

  if #new_lines == 0 or not buf then
    return nil
  end

  if is_insertion then
    output_window.set_lines(new_lines, target_line, target_line)
  else
    local extra_newline = vim.tbl_extend('keep', {}, new_lines)
    table.insert(extra_newline, '')
    target_line = target_line - 1
    output_window.set_lines(extra_newline, target_line)
  end

  -- update actions and extmarks after the insertion because that may
  -- adjust target_line (e.g. when we we're replacing the double newline at
  -- the end)

  if part_id and formatted_data.actions then
    M._render_state:add_actions(part_id, formatted_data.actions, target_line)
  end

  output_window.set_extmarks(extmarks, target_line)

  return {
    line_start = target_line,
    line_end = target_line + #new_lines - 1,
  }
end

---Insert new part, either at end of buffer or in the middle for out-of-order parts
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

  local is_current_message = state.current_message
    and state.current_message.info
    and state.current_message.info.id == cached.message_id

  if is_current_message then
    -- NOTE: we're inserting a part for the current message, just add it to the end

    local range = M._write_formatted_data(formatted_data, part_id)
    if not range then
      return false
    end

    M._render_state:set_part(cached.part, range.line_start, range.line_end)

    M._last_part_formatted = { part_id = part_id, formatted_data = formatted_data }

    return true
  end

  -- NOTE: We're inserting a part for the first time for a previous message. We need to find
  -- the insertion line (after the last part of this message or after the message header if
  -- no parts).
  local insertion_line = M._get_insertion_point_for_part(part_id, cached.message_id)
  if not insertion_line then
    return false
  end

  local range = M._write_formatted_data(formatted_data, part_id, insertion_line)
  if not range then
    return false
  end

  local line_count = #formatted_data.lines
  M._render_state:shift_all(insertion_line, line_count)

  M._render_state:set_part(cached.part, range.line_start, range.line_end)

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

  local old_formatted = M._last_part_formatted
  local can_optimize = old_formatted
    and old_formatted.part_id == part_id
    and old_formatted.formatted_data
    and old_formatted.formatted_data.lines

  local lines_to_write = new_lines
  local write_start_line = cached.line_start

  if can_optimize then
    -- NOTE: This is an optimization to only replace the lines that are different
    -- if we're replacing the most recently formatted part.

    ---@cast old_formatted { formatted_data: { lines: string[] } }
    local old_lines = old_formatted.formatted_data.lines
    local first_diff_line = nil

    -- Find the first line that's different
    for i = 1, math.min(#old_lines, new_line_count) do
      if old_lines[i] ~= new_lines[i] then
        first_diff_line = i
        break
      end
    end

    if not first_diff_line and new_line_count > #old_lines then
      -- The old lines all matched but maybe there are more new lines
      first_diff_line = #old_lines + 1
    end

    if first_diff_line then
      lines_to_write = vim.list_slice(new_lines, first_diff_line, new_line_count)
      write_start_line = cached.line_start + first_diff_line - 1
    elseif new_line_count == #old_lines then
      -- Nothing was different, so we're done
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
    M._render_state:add_actions(part_id, formatted_data.actions, cached.line_start + 1)
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

  if cached.line_start == 0 and cached.line_end == 0 then
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

  if message.info.role == 'user' then
    M.scroll_to_bottom(true)
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
    local error_changed = not vim.deep_equal(found_msg.info.error, msg.info.error)

    found_msg.info = msg.info

    --- NOTE: error handling is a bit messy because errors come in on messages
    --- but we want to display the error at the end. In this case, we an error
    --- was added to this message. We find the last part and re-render it to
    --- display the message. If there are no parts, we'll re-render the message

    if error_changed and not revert_index then
      local last_part_id = M._get_last_part_for_message(found_msg)
      if last_part_id then
        M._rerender_part(last_part_id)
      else
        local header_data = formatter.format_message_header(found_msg)
        M._replace_message_in_buffer(msg.info.id, header_data)
      end
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

  local prev_last_part_id = M._get_last_part_for_message(message)
  local is_last_part = is_new_part or (prev_last_part_id == part.id)

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
    local rendered_part = M._render_state:update_part_data(part)
    -- NOTE: This isn't the first time we've seen the part but we haven't rendered it previously
    -- so try and render it this time by setting is_new_part = true (otherwise we'd call
    -- _replace_message_in_buffer and it wouldn't do anything because the part hasn't been rendered)
    if not rendered_part or (not rendered_part.line_start and not rendered_part.line_end) then
      is_new_part = true
    end
  end

  local formatted = formatter.format_part(part, message, is_last_part)

  if part.callID and state.pending_permissions then
    for _, permission in ipairs(state.pending_permissions) do
      local tool = permission.tool
      local perm_callID = tool and tool.callID or permission.callID
      local perm_messageID = tool and tool.messageID or permission.messageID

      if perm_callID == part.callID and perm_messageID == part.messageID then
        require('opencode.ui.permission_window').update_permission_from_part(permission.id, part)
        break
      end
    end
  end

  if revert_index and is_new_part then
    return
  end

  if is_new_part then
    M._insert_part_to_buffer(part.id, formatted)

    if message.info.error then
      --- NOTE: More error display code. As mentioned above, errors come in on messages
      --- but we want to display them after parts so we tack the error onto the last
      --- part. When a part is added and there's an error, we need to rerender
      --- previous last part so it doesn't also display the message. If there was no previous
      --- part, then we need to rerender the header so it doesn't display the error

      if not prev_last_part_id then
        -- no previous part, we're the first part, re-render the message header
        -- so it doesn't also display the error
        local header_data = formatter.format_message_header(message)
        M._replace_message_in_buffer(part.messageID, header_data)
      elseif prev_last_part_id ~= part.id then
        M._rerender_part(prev_last_part_id)
      end
    end
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
  vim.notify('Session has been compacted')
end

---Event handler for session.updated events
---@param properties {info: Session}
function M.on_session_updated(properties)
  if not properties or not properties.info or not state.active_session then
    return
  end

  local updated_session = properties.info
  if not updated_session.id or updated_session.id ~= state.active_session.id then
    return
  end

  local current_session = state.active_session
  local revert_changed = not vim.deep_equal(current_session.revert, updated_session.revert)
  local previous_title = current_session.title

  if not vim.deep_equal(current_session, updated_session) then
    for key in pairs(current_session) do
      if updated_session[key] == nil then
        current_session[key] = nil
      end
    end

    for key, value in pairs(updated_session) do
      current_session[key] = value
    end

    if updated_session.title and updated_session.title ~= previous_title then
      require('opencode.ui.topbar').render()
    end
  end

  if revert_changed then
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
---Re-renders part that requires permission and adds to permission window
---@param permission OpencodePermission Event properties
function M.on_permission_updated(permission)
  local tool = permission.tool

  ---@TODO this is for backward compatibility, remove later
  local callID = tool and tool.callID or permission.callID
  local messageID = tool and tool.messageID or permission.messageID

  if not permission or not messageID or not callID then
    return
  end

  -- Add permission to pending queue
  if not state.pending_permissions then
    state.pending_permissions = {}
  end

  -- Check if permission already exists in queue
  local existing_index = nil
  for i, existing in ipairs(state.pending_permissions) do
    if existing.id == permission.id then
      existing_index = i
      break
    end
  end

  local permissions = vim.deepcopy(state.pending_permissions)
  if existing_index then
    permissions[existing_index] = permission
  else
    table.insert(permissions, permission)
  end
  state.pending_permissions = permissions

  permission_window.add_permission(permission)

  M.render_permissions_display()

  M._rerender_part('permission-display-part')
  M.scroll_to_bottom(true)
end

---Event handler for permission.replied events
---Re-renders part after permission is resolved and removes from window
---@param properties {sessionID: string, permissionID?: string,requestID?: string, response: string}|{} Event properties
function M.on_permission_replied(properties)
  if not properties then
    return
  end

  local permission_id = properties.permissionID or properties.requestID

  if permission_id then
    permission_window.remove_permission(permission_id)
    state.pending_permissions = vim.deepcopy(permission_window.get_all_permissions())
    if #state.pending_permissions == 0 then
      M._remove_part_from_buffer('permission-display-part')
      M._remove_message_from_buffer('permission-display-message')
    end
    M._rerender_part('permission-display-part')
  end
end

---Event handler for question.asked events
---Shows the question picker UI for the user to answer
---@param properties OpencodeQuestionRequest Event properties
function M.on_question_asked(properties)
  if not properties or not properties.id or not properties.questions then
    return
  end

  if not state.active_session or properties.sessionID ~= state.active_session.id then
    return
  end

  local question_window = require('opencode.ui.question_window')
  question_window.show_question(properties)
end

function M.on_file_edited(properties)
  vim.cmd('checktime')
  if config.hooks and config.hooks.on_file_edited then
    pcall(config.hooks.on_file_edited, properties.file)
  end
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

---Find the last part in a message
---@param message OpencodeMessage The message containing the parts
---@return string? last_part_id The ID of the last part
function M._get_last_part_for_message(message)
  if not message or not message.parts or #message.parts == 0 then
    return nil
  end

  for i = #message.parts, 1, -1 do
    local part = message.parts[i]
    if part.type ~= 'step-start' and part.type ~= 'step-finish' and part.id then
      return part.id
    end
  end

  return nil
end

---Get insertion point for an out-of-order part
---@param part_id string The part ID to insert
---@param message_id string The message ID the part belongs to
---@return integer? insertion_line The line to insert at (1-indexed), or nil on error
function M._get_insertion_point_for_part(part_id, message_id)
  local rendered_message = M._render_state:get_message(message_id)
  if not rendered_message or not rendered_message.message then
    return nil
  end

  local message = rendered_message.message

  local insertion_line = rendered_message.line_end and (rendered_message.line_end + 1)
  if not insertion_line then
    return nil
  end

  local current_part_index = nil
  if message.parts then
    for i, part in ipairs(message.parts) do
      if part.id == part_id then
        current_part_index = i
        break
      end
    end
  end

  if not current_part_index then
    return insertion_line
  end

  for i = current_part_index - 1, 1, -1 do
    local prev_part = message.parts[i]
    if prev_part and prev_part.id then
      local prev_rendered = M._render_state:get_part(prev_part.id)

      if prev_rendered and prev_rendered.line_end then
        return prev_rendered.line_end + 1
      end
    end
  end

  return insertion_line
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
  local last_part_id = M._get_last_part_for_message(message)
  local is_last_part = (last_part_id == part_id)
  local formatted = formatter.format_part(part, message, is_last_part)

  M._replace_part_in_buffer(part_id, formatted)
end

---Event handler for focus changes
---Re-renders part associated with current permission for displaying global shortcuts or buffer-local ones
function M.on_focus_changed()
  -- Check permission window first, fallback to state
  local current_permission = permission_window.get_all_permissions()[1]

  if not current_permission then
    return
  end

  M._rerender_part('permission-display-part')
  trigger_on_data_rendered()
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

---Get all actions available at a specific line
---@param line integer 0-indexed line number
---@return table[] List of actions available at that line
function M.get_actions_for_line(line)
  return M._render_state:get_actions_at_line(line)
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

---Get rendered message by ID
---@param message_id string Message ID
---@return RenderedMessage|nil Rendered message or nil if not found
function M.get_rendered_message(message_id)
  local rendered_msg = M._render_state:get_message(message_id)
  if rendered_msg then
    return rendered_msg
  end
  return nil
end

return M
