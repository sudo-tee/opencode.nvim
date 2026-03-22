local ctx = require('opencode.ui.renderer.ctx')
local state = require('opencode.state')
local formatter = require('opencode.ui.formatter')
local output_window = require('opencode.ui.output_window')

local M = {}

local function has_extmarks(extmarks)
  return type(extmarks) == 'table' and next(extmarks) ~= nil
end

local function has_actions(actions)
  return type(actions) == 'table' and #actions > 0
end

---@param old_lines string[]
---@param new_lines string[]
---@return integer, integer
local function get_shared_prefix_suffix(old_lines, new_lines)
  local old_count = #old_lines
  local new_count = #new_lines
  local prefix = 0

  while prefix < old_count and prefix < new_count do
    if old_lines[prefix + 1] ~= new_lines[prefix + 1] then
      break
    end
    prefix = prefix + 1
  end

  local suffix = 0
  while suffix < (old_count - prefix) and suffix < (new_count - prefix) do
    if old_lines[old_count - suffix] ~= new_lines[new_count - suffix] then
      break
    end
    suffix = suffix + 1
  end

  return prefix, suffix
end

---Find the last renderable part ID in a message (skips step-start/finish)
---@param message OpencodeMessage
---@return string?
function M.get_last_part_for_message(message)
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

---Find the first non-synthetic text part ID in a message
---@param message OpencodeMessage
---@return string?
function M.find_text_part_for_message(message)
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

---Find part ID by call ID and message ID
---@param call_id string
---@param message_id string
---@return string?
function M.find_part_by_call_id(call_id, message_id)
  return ctx.render_state:get_part_by_call_id(call_id, message_id)
end

---Determine where to insert an out-of-order part (after the last rendered
---sibling, or right after the message header if no siblings are rendered yet)
---@param part_id string
---@param message_id string
---@return integer?
local function get_insertion_point_for_part(part_id, message_id)
  local rendered_message = ctx.render_state:get_message(message_id)
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

  -- Walk backwards through earlier siblings to find the last rendered one
  for i = current_part_index - 1, 1, -1 do
    local prev_part = message.parts[i]
    if prev_part and prev_part.id then
      local prev_rendered = ctx.render_state:get_part(prev_part.id)
      if prev_rendered and prev_rendered.line_end then
        return prev_rendered.line_end + 1
      end
    end
  end

  return insertion_line
end

---Append formatted data to the end of the buffer, or insert at start_line.
---Returns the range of lines written, or nil if nothing was written.
---@param formatted_data Output
---@param part_id? string  When provided, actions are registered for this part
---@param start_line? integer  When provided, content is inserted here (shifts down)
---@return {line_start: integer, line_end: integer}?
function M.write_formatted_data(formatted_data, part_id, start_line)
  if not state.windows or not state.windows.output_buf then
    return nil
  end

  local new_lines = formatted_data.lines
  if #new_lines == 0 then
    return nil
  end

  local is_insertion = start_line ~= nil
  local target_line = start_line or output_window.get_buf_line_count()

  if is_insertion then
    output_window.set_lines(new_lines, target_line, target_line)
  else
    -- Append: overlap the last buffer line  with our lines
    target_line = target_line - 1
    local append_lines = table.move(new_lines, 1, #new_lines, 1, {})
    append_lines[#append_lines + 1] = ''
    output_window.set_lines(append_lines, target_line)
  end

  if part_id and formatted_data.actions then
    ctx.render_state:add_actions(part_id, formatted_data.actions, target_line)
  end

  if has_extmarks(formatted_data.extmarks) then
    output_window.set_extmarks(formatted_data.extmarks, target_line)
    local part_data = ctx.render_state:get_part(part_id)
    if part_data then
      part_data.has_extmarks = true
    end
  end

  return { line_start = target_line, line_end = target_line + #new_lines - 1 }
end

---Insert a new part into the buffer.
---Appends if the part belongs to the current message; inserts in-order otherwise.
---@param part_id string
---@param formatted_data Output
---@return boolean
function M.insert_part(part_id, formatted_data)
  local cached = ctx.render_state:get_part(part_id)
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
    local range = M.write_formatted_data(formatted_data, part_id)
    if not range then
      return false
    end
    ctx.render_state:set_part(cached.part, range.line_start, range.line_end)
    ctx.last_part_formatted = { part_id = part_id, formatted_data = formatted_data }
    return true
  end

  -- Out-of-order part: find the correct insertion point
  local insertion_line = get_insertion_point_for_part(part_id, cached.message_id)
  if not insertion_line then
    return false
  end

  local range = M.write_formatted_data(formatted_data, part_id, insertion_line)
  if not range then
    return false
  end

  ctx.render_state:shift_all(insertion_line, #formatted_data.lines)
  ctx.render_state:set_part(cached.part, range.line_start, range.line_end)
  return true
end

---Replace an existing part in the buffer.
---Only writes lines that differ from the previous render (diff optimisation).
---@param part_id string
---@param formatted_data Output
---@return boolean
function M.replace_part(part_id, formatted_data)
  local cached = ctx.render_state:get_part(part_id)
  if not cached or not cached.line_start or not cached.line_end then
    return false
  end

  local new_lines = formatted_data.lines
  local new_line_count = #new_lines
  local next_has_extmarks = has_extmarks(formatted_data.extmarks)
  local had_extmarks = cached.has_extmarks == true
  local next_has_actions = has_actions(formatted_data.actions)
  local had_actions = cached.actions and #cached.actions > 0
  local old_buf_line_count = output_window.get_buf_line_count()
  local was_tail_part = cached.line_end == old_buf_line_count - 1

  -- Diff optimisation: skip lines that haven't changed since the last render
  local old = ctx.last_part_formatted
  local lines_to_write = new_lines
  local write_start = cached.line_start
  local write_end = cached.line_end + 1
  local prefix = 0
  local suffix = 0

  if old and old.part_id == part_id and old.formatted_data and old.formatted_data.lines then
    local old_lines = old.formatted_data.lines
    prefix, suffix = get_shared_prefix_suffix(old_lines, new_lines)

    if prefix == #old_lines and prefix == new_line_count then
      if not had_extmarks and not next_has_extmarks and not had_actions and not next_has_actions then
        ctx.last_part_formatted = { part_id = part_id, formatted_data = formatted_data }
        return true
      end
    end

    local replace_from = prefix + 1
    local replace_to = new_line_count - suffix
    lines_to_write = replace_from <= replace_to and vim.list_slice(new_lines, replace_from, replace_to) or {}
    write_start = cached.line_start + prefix
    write_end = cached.line_end + 1 - suffix
  end

  if had_actions or next_has_actions then
    ctx.render_state:clear_actions(part_id)
  end

  output_window.begin_update()
  if had_extmarks or next_has_extmarks then
    output_window.clear_extmarks(cached.line_start - 1, cached.line_end + 1)
  end
  output_window.set_lines(lines_to_write, write_start, write_end)

  local new_line_end = cached.line_start + new_line_count - 1
  if next_has_extmarks then
    output_window.set_extmarks(formatted_data.extmarks, cached.line_start)
  end
  output_window.end_update()
  cached.has_extmarks = next_has_extmarks

  if next_has_actions then
    ctx.render_state:add_actions(part_id, formatted_data.actions, cached.line_start + 1)
  end

  if new_line_end ~= cached.line_end then
    if was_tail_part then
      ctx.render_state:set_part(cached.part, cached.line_start, new_line_end)
    else
      ctx.render_state:update_part_lines(part_id, cached.line_start, new_line_end)
    end
  end

  ctx.last_part_formatted = { part_id = part_id, formatted_data = formatted_data }
  return true
end

---Remove a part and its extmarks from the buffer
---@param part_id string
function M.remove_part(part_id)
  local cached = ctx.render_state:get_part(part_id)
  if not cached or not cached.line_start or not cached.line_end then
    return
  end
  output_window.begin_update()
  output_window.clear_extmarks(cached.line_start - 1, cached.line_end + 1)
  output_window.set_lines({}, cached.line_start, cached.line_end + 1)
  output_window.end_update()
  ctx.render_state:remove_part(part_id)
end

---Write a message header into the buffer
---@param message OpencodeMessage
function M.add_message(message)
  local header_data = formatter.format_message_header(message)
  local range = M.write_formatted_data(header_data)
  if range then
    ctx.render_state:set_message(message, range.line_start, range.line_end)
  end
end

---Replace an existing message header in the buffer
---@param message_id string
---@param formatted_data Output
---@return boolean
function M.replace_message(message_id, formatted_data)
  local cached = ctx.render_state:get_message(message_id)
  if not cached or not cached.line_start or not cached.line_end then
    return false
  end

  local new_lines = formatted_data.lines
  local new_line_count = #new_lines

  output_window.begin_update()
  output_window.clear_extmarks(cached.line_start, cached.line_end + 1)
  output_window.set_lines(new_lines, cached.line_start, cached.line_end + 1)
  output_window.set_extmarks(formatted_data.extmarks, cached.line_start)
  output_window.end_update()

  local old_line_end = cached.line_end
  local new_line_end = cached.line_start + new_line_count - 1

  ctx.render_state:set_message(cached.message, cached.line_start, new_line_end)

  local delta = new_line_end - old_line_end
  if delta ~= 0 then
    ctx.render_state:shift_all(old_line_end + 1, delta)
  end

  return true
end

---Remove a message header and its extmarks from the buffer
---@param message_id string
function M.remove_message(message_id)
  local cached = ctx.render_state:get_message(message_id)
  if not cached or not cached.line_start or not cached.line_end then
    return
  end
  if not state.windows or not state.windows.output_buf then
    return
  end
  if cached.line_start == 0 and cached.line_end == 0 then
    return
  end
  output_window.begin_update()
  output_window.clear_extmarks(cached.line_start - 1, cached.line_end + 1)
  output_window.set_lines({}, cached.line_start, cached.line_end + 1)
  output_window.end_update()
  ctx.render_state:remove_message(message_id)
end

---Re-render an existing part using its current data from render_state
---@param part_id string
function M.rerender_part(part_id)
  local cached = ctx.render_state:get_part(part_id)
  if not cached or not cached.part then
    return
  end

  local rendered_message = ctx.render_state:get_message(cached.message_id)
  if not rendered_message or not rendered_message.message then
    return
  end

  local message = rendered_message.message
  local is_last_part = (M.get_last_part_for_message(message) == part_id)
  local formatted = formatter.format_part(cached.part, message, is_last_part, function(session_id)
    return ctx.render_state:get_child_session_parts(session_id)
  end)

  M.replace_part(part_id, formatted)
end

---Re-render the task-tool part that owns the given child session
---@param child_session_id string
function M.rerender_task_tool_for_child_session(child_session_id)
  local part_id = ctx.render_state:get_task_part_by_child_session(child_session_id)
  if part_id then
    M.rerender_part(part_id)
  end
end

return M
