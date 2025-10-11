local state = require('opencode.state')

local M = {}

M._part_cache = {}
M._message_cache = {}
M._session_id = nil
M._namespace = vim.api.nvim_create_namespace('opencode_stream')

function M.reset()
  M._part_cache = {}
  M._message_cache = {}
  M._session_id = nil
  state.messages = {}
end

function M._get_buffer_line_count()
  if not state.windows or not state.windows.output_buf then
    return 0
  end
  return vim.api.nvim_buf_line_count(state.windows.output_buf)
end

function M._is_streaming_update(part_id, new_text)
  local cached = M._part_cache[part_id]
  if not cached or not cached.text then
    return false
  end

  local old_text = cached.text
  if #new_text < #old_text then
    return false
  end

  return new_text:sub(1, #old_text) == old_text
end

function M._calculate_delta(part_id, new_text)
  local cached = M._part_cache[part_id]
  if not cached or not cached.text then
    return new_text
  end

  local old_text = cached.text
  return new_text:sub(#old_text + 1)
end

function M._shift_lines(from_line, delta)
  if delta == 0 then
    return
  end

  for part_id, part_data in pairs(M._part_cache) do
    if part_data.line_start and part_data.line_start >= from_line then
      part_data.line_start = part_data.line_start + delta
      if part_data.line_end then
        part_data.line_end = part_data.line_end + delta
      end
    end
  end

  for msg_id, msg_data in pairs(M._message_cache) do
    if msg_data.line_start and msg_data.line_start >= from_line then
      msg_data.line_start = msg_data.line_start + delta
      if msg_data.line_end then
        msg_data.line_end = msg_data.line_end + delta
      end
    end
  end
end

function M._apply_extmarks(buf, line_offset, extmarks)
  if not extmarks or type(extmarks) ~= 'table' then
    return
  end

  for line_idx, marks in pairs(extmarks) do
    if type(marks) == 'table' then
      for _, mark in ipairs(marks) do
        local actual_mark = mark
        if type(mark) == 'function' then
          actual_mark = mark()
        end

        if type(actual_mark) == 'table' then
          local target_line = line_offset + line_idx - 1
          pcall(vim.api.nvim_buf_set_extmark, buf, M._namespace, target_line, 0, actual_mark)
        end
      end
    end
  end
end

function M._set_lines(buf, start_line, end_line, strict_indexing, lines)
  vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
  local ok, err = pcall(vim.api.nvim_buf_set_lines, buf, start_line, end_line, strict_indexing, lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
  return ok, err
end

function M._text_to_lines(text)
  if not text or text == '' then
    return {}
  end
  local lines = {}
  local had_trailing_newline = text:sub(-1) == '\n'
  for line in (text .. '\n'):gmatch('([^\n]*)\n') do
    table.insert(lines, line)
  end
  if not had_trailing_newline and #lines > 0 and lines[#lines] == '' then
    table.remove(lines)
  end
  return lines
end

function M._append_delta_to_buffer(part_id, delta)
  local cached = M._part_cache[part_id]
  if not cached or not cached.line_end then
    return false
  end

  if not state.windows or not state.windows.output_buf then
    return false
  end

  local buf = state.windows.output_buf
  local delta_lines = M._text_to_lines(delta)

  if #delta_lines == 0 then
    return true
  end

  local last_line = vim.api.nvim_buf_get_lines(buf, cached.line_end, cached.line_end + 1, false)[1] or ''
  local first_delta_line = table.remove(delta_lines, 1)
  local new_last_line = last_line .. first_delta_line

  local ok = M._set_lines(buf, cached.line_end, cached.line_end + 1, false, { new_last_line })

  if ok and #delta_lines > 0 then
    ok = M._set_lines(buf, cached.line_end + 1, cached.line_end + 1, false, delta_lines)
    if ok then
      local old_line_end = cached.line_end
      cached.line_end = cached.line_end + #delta_lines
      M._shift_lines(old_line_end + 1, #delta_lines)
    end
  end

  return ok
end

function M._scroll_to_bottom()
  vim.schedule(function()
    -- vim.notify('scrolling to bottom')
    require('opencode.ui.ui').scroll_to_bottom()
  end)
end

function M._write_formatted_data(formatted_data)
  if not state.windows or not state.windows.output_buf then
    return nil
  end

  local buf = state.windows.output_buf
  local buf_lines = M._get_buffer_line_count()
  local new_lines = formatted_data.lines

  if #new_lines == 0 then
    return nil
  end

  local ok, err = M._set_lines(buf, buf_lines, -1, false, new_lines)

  if not ok then
    return nil
  end

  M._apply_extmarks(buf, buf_lines, formatted_data.extmarks)

  return {
    line_start = buf_lines,
    line_end = buf_lines + #new_lines - 1,
  }
end

function M._write_message_header(message, msg_idx)
  local formatter = require('opencode.ui.session_formatter')
  local header_data = formatter.format_message_header_isolated(message, msg_idx)
  local line_range = M._write_formatted_data(header_data)
  return line_range
end

function M._insert_part_to_buffer(part_id, formatted_data)
  local cached = M._part_cache[part_id]
  if not cached then
    return false
  end

  if not state.windows or not state.windows.output_buf then
    return false
  end

  local buf = state.windows.output_buf
  local new_lines = formatted_data.lines
  local buf_lines = M._get_buffer_line_count()

  if #new_lines == 0 then
    return true
  end

  local ok = M._set_lines(buf, buf_lines, -1, false, new_lines)

  if not ok then
    return false
  end

  cached.line_start = buf_lines
  cached.line_end = buf_lines + #new_lines - 1

  if #new_lines > 1 and new_lines[#new_lines] == '' then
    cached.line_end = cached.line_end - 1
  end

  M._apply_extmarks(buf, cached.line_start, formatted_data.extmarks)

  return true
end

function M._replace_part_in_buffer(part_id, formatted_data)
  local cached = M._part_cache[part_id]
  if not cached or not cached.line_start or not cached.line_end then
    return false
  end

  if not state.windows or not state.windows.output_buf then
    return false
  end

  local buf = state.windows.output_buf
  local new_lines = formatted_data.lines

  local old_line_count = cached.line_end - cached.line_start + 1
  local new_line_count = #new_lines

  local ok = M._set_lines(buf, cached.line_start, cached.line_end + 1, false, new_lines)

  if not ok then
    return false
  end

  cached.line_end = cached.line_start + new_line_count - 1

  M._apply_extmarks(buf, cached.line_start, formatted_data.extmarks)

  local line_delta = new_line_count - old_line_count
  if line_delta ~= 0 then
    M._shift_lines(cached.line_end + 1, line_delta)
  end

  return true
end

function M._remove_part_from_buffer(part_id)
  local cached = M._part_cache[part_id]
  if not cached or not cached.line_start or not cached.line_end then
    M._part_cache[part_id] = nil
    return
  end

  if not state.windows or not state.windows.output_buf then
    M._part_cache[part_id] = nil
    return
  end

  local buf = state.windows.output_buf
  local line_count = cached.line_end - cached.line_start + 1

  M._set_lines(buf, cached.line_start, cached.line_end + 1, false, {})

  M._shift_lines(cached.line_end + 1, -line_count)
  M._part_cache[part_id] = nil
end

function M.handle_message_updated(event)
  if not event or not event.properties or not event.properties.info then
    return
  end

  local message = event.properties.info
  if not message.id or not message.sessionID then
    return
  end

  if M._session_id and M._session_id ~= message.sessionID then
    -- TODO: there's probably more we need to do here
    M.reset()
  end

  M._session_id = message.sessionID

  if not state.messages then
    state.messages = {}
  end

  local found_idx = nil
  for i = #state.messages, math.max(1, #state.messages - 2), -1 do
    if state.messages[i].info.id == message.id then
      found_idx = i
      break
    end
  end

  if found_idx then
    -- vim.notify('Message updated? ' .. vim.inspect(event), vim.log.levels.WARN)
    -- I think this is mostly for book keeping / stats (tokens update)
    state.messages[found_idx].info = message
  else
    table.insert(state.messages, { info = message, parts = {} })
    found_idx = #state.messages

    local header_range = M._write_message_header(message, found_idx)
    if header_range then
      if not M._message_cache[message.id] then
        M._message_cache[message.id] = {}
      end
      M._message_cache[message.id].line_start = header_range.line_start
      M._message_cache[message.id].line_end = header_range.line_end
    end
  end

  M._scroll_to_bottom()
end

function M.handle_part_updated(event)
  if not event or not event.properties or not event.properties.part then
    return
  end

  local part = event.properties.part
  if not part.id or not part.messageID or not part.sessionID then
    return
  end

  if M._session_id and M._session_id ~= part.sessionID then
    vim.notify('Session id does not match, discarding part: ' .. vim.inspect(part), vim.log.levels.WARN)
    return
  end

  if not state.messages then
    state.messages = {}
  end

  local msg_wrapper, msg_idx
  for i = #state.messages, math.max(1, #state.messages - 2), -1 do
    if state.messages[i].info.id == part.messageID then
      msg_wrapper = state.messages[i]
      msg_idx = i
      break
    end
  end

  if not msg_wrapper then
    vim.notify('Could not find message for part: ' .. vim.inspect(part), vim.log.levels.WARN)
    return
  end

  local message = msg_wrapper.info
  msg_wrapper.parts = msg_wrapper.parts or {}

  local is_new_part = not M._part_cache[part.id]
  local part_idx = nil

  if is_new_part then
    table.insert(msg_wrapper.parts, part)
    part_idx = #msg_wrapper.parts
  else
    for i, p in ipairs(msg_wrapper.parts) do
      if p.id == part.id then
        msg_wrapper.parts[i] = part
        part_idx = i
        break
      end
    end
  end

  local part_text = part.text or ''

  if not is_new_part and M._is_streaming_update(part.id, part_text) then
    local delta = M._calculate_delta(part.id, part_text)
    M._append_delta_to_buffer(part.id, delta)
    M._part_cache[part.id].text = part_text
    M._scroll_to_bottom()
    return
  end

  if not M._part_cache[part.id] then
    M._part_cache[part.id] = {
      text = nil,
      line_start = nil,
      line_end = nil,
      message_id = part.messageID,
      type = part.type,
    }
  end

  local formatter = require('opencode.ui.session_formatter')
  local message_with_parts = vim.tbl_extend('force', message, { parts = msg_wrapper.parts })
  local ok, formatted = pcall(formatter.format_part_isolated, part, {
    msg_idx = msg_idx,
    part_idx = part_idx,
    role = message.role,
    message = message_with_parts,
  })

  if not ok then
    vim.notify('format_part_isolated error: ' .. tostring(formatted), vim.log.levels.ERROR)
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

function M.handle_part_removed(event)
  -- XXX: I don't have any sessions that remove messages so this code is
  -- currently untested
  if not event or not event.properties then
    return
  end

  local part_id = event.properties.partID
  if not part_id then
    return
  end

  local cached = M._part_cache[part_id]
  if cached and cached.message_id then
    if state.messages then
      for i = #state.messages, math.max(1, #state.messages - 2), -1 do
        if state.messages[i].info.id == cached.message_id then
          if state.messages[i].parts then
            for j, part in ipairs(state.messages[i].parts) do
              if part.id == part_id then
                table.remove(state.messages[i].parts, j)
                break
              end
            end
          end
          break
        end
      end
    end
  end

  M._remove_part_from_buffer(part_id)
end

function M.handle_message_removed(event)
  -- XXX: I don't have any sessions that remove messages so this code is
  -- currently untested
  if not event or not event.properties then
    return
  end

  local message_id = event.properties.messageID
  if not message_id then
    return
  end

  if not state.messages then
    return
  end

  local message_idx = nil
  for i = #state.messages, 1, -1 do
    if state.messages[i].info.id == message_id then
      message_idx = i
      break
    end
  end

  if not message_idx then
    return
  end

  local msg_wrapper = state.messages[message_idx]
  if msg_wrapper.parts then
    for _, part in ipairs(msg_wrapper.parts) do
      if part.id then
        M._remove_part_from_buffer(part.id)
      end
    end
  end

  table.remove(state.messages, message_idx)

  if M._message_cache[message_id] then
    M._message_cache[message_id] = nil
  end
end

function M.handle_session_compacted()
  M.reset()
  vim.notify('handle_session_compacted')
  require('opencode.ui.output_renderer').render(state.windows, true)
end

function M.reset_and_render()
  M.reset()
  vim.notify('reset and render:\n' .. debug.traceback())
  require('opencode.ui.output_renderer').render(state.windows, true)
end

function M.handle_session_error(event)
  if not event or not event.properties or not event.properties.error then
    return
  end

  local error_data = event.properties.error
  local error_message = error_data.data and error_data.data.message or vim.inspect(error_data)

  local formatter = require('opencode.ui.session_formatter')
  local formatted = formatter.format_error_callout(error_message)

  M._write_formatted_data(formatted)
  M._scroll_to_bottom()
end

return M
