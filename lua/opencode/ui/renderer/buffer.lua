local state = require('opencode.state')
local output_window = require('opencode.ui.output_window')

---Low-level buffer operations for the renderer.
---All functions operate on state.windows.output_buf.
---Callers own the render-state bookkeeping; this module only touches nvim buffers.
local M = {}

---Append or insert formatted data into the output buffer.
---
---When `start_line` is nil the data is appended after the last existing line,
---separated from it by a blank line.  When `start_line` is given the lines are
---inserted at that position, pushing subsequent content down.
---
---@param render_state RenderState
---@param formatted_data Output
---@param part_id? string When set, actions from `formatted_data` are registered.
---@param start_line? integer 1-indexed insertion line (nil = append).
---@return {line_start: integer, line_end: integer}? Written line range, nil on failure.
function M.write(render_state, formatted_data, part_id, start_line)
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
    -- Append: add a blank separator then the new lines.
    local with_newline = vim.tbl_extend('keep', {}, new_lines)
    table.insert(with_newline, '')
    target_line = target_line - 1
    output_window.set_lines(with_newline, target_line)
  end

  if part_id and formatted_data.actions then
    render_state:add_actions(part_id, formatted_data.actions, target_line)
  end

  output_window.set_extmarks(formatted_data.extmarks, target_line)

  return {
    line_start = target_line,
    line_end = target_line + #new_lines - 1,
  }
end

---Insert a part into the buffer for the first time.
---
---Parts belonging to the *current* message are appended; parts for earlier
---messages are inserted at the correct position so the order matches the
---logical message order.
---
---@param render_state RenderState
---@param part_id string
---@param formatted_data Output
---@param last_formatted { part_id: string?, formatted_data: Output? }
---@return boolean success
function M.insert_part(render_state, part_id, formatted_data, last_formatted)
  local cached = render_state:get_part(part_id)
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
    local range = M.write(render_state, formatted_data, part_id)
    if not range then
      return false
    end
    render_state:set_part(cached.part, range.line_start, range.line_end)
    last_formatted.part_id = part_id
    last_formatted.formatted_data = formatted_data
    return true
  end

  -- Out-of-order part: find where it belongs relative to sibling parts.
  local insertion_line = M._insertion_point(render_state, part_id, cached.message_id)
  if not insertion_line then
    return false
  end

  local range = M.write(render_state, formatted_data, part_id, insertion_line)
  if not range then
    return false
  end

  render_state:shift_all(insertion_line, #formatted_data.lines)
  render_state:set_part(cached.part, range.line_start, range.line_end)
  return true
end

---Replace an already-rendered part in the buffer.
---
---Only rewrites lines that actually changed (compared to `last_formatted`)
---when replacing the most-recently-written part.
---
---@param render_state RenderState
---@param part_id string
---@param formatted_data Output
---@param last_formatted { part_id: string?, formatted_data: Output? }
---@return boolean success
function M.replace_part(render_state, part_id, formatted_data, last_formatted)
  local cached = render_state:get_part(part_id)
  if not cached or not cached.line_start or not cached.line_end then
    return false
  end

  local new_lines = formatted_data.lines
  local new_line_count = #new_lines

  -- Optimisation: skip lines that haven't changed.
  local write_start_line = cached.line_start
  local lines_to_write = new_lines

  local old = last_formatted
  if old and old.part_id == part_id and old.formatted_data and old.formatted_data.lines then
    local old_lines = old.formatted_data.lines
    local first_diff = nil

    for i = 1, math.min(#old_lines, new_line_count) do
      if old_lines[i] ~= new_lines[i] then
        first_diff = i
        break
      end
    end

    if not first_diff and new_line_count > #old_lines then
      first_diff = #old_lines + 1
    end

    if first_diff then
      lines_to_write = vim.list_slice(new_lines, first_diff, new_line_count)
      write_start_line = cached.line_start + first_diff - 1
    elseif new_line_count == #old_lines then
      -- Nothing changed.
      last_formatted.part_id = part_id
      last_formatted.formatted_data = formatted_data
      return true
    end
  end

  render_state:clear_actions(part_id)
  output_window.clear_extmarks(cached.line_start - 1, cached.line_end + 1)
  output_window.set_lines(lines_to_write, write_start_line, cached.line_end + 1)

  local new_line_end = cached.line_start + new_line_count - 1
  output_window.set_extmarks(formatted_data.extmarks, cached.line_start)

  if formatted_data.actions then
    render_state:add_actions(part_id, formatted_data.actions, cached.line_start + 1)
  end

  render_state:update_part_lines(part_id, cached.line_start, new_line_end)

  last_formatted.part_id = part_id
  last_formatted.formatted_data = formatted_data
  return true
end

---Remove a rendered part from the buffer.
---@param render_state RenderState
---@param part_id string
function M.remove_part(render_state, part_id)
  local cached = render_state:get_part(part_id)
  if not cached or not cached.line_start or not cached.line_end then
    return
  end

  if not state.windows or not state.windows.output_buf then
    return
  end

  output_window.clear_extmarks(cached.line_start - 1, cached.line_end)
  output_window.set_lines({}, cached.line_start - 1, cached.line_end)
  render_state:remove_part(part_id)
end

---Remove a rendered message header from the buffer.
---@param render_state RenderState
---@param message_id string
function M.remove_message(render_state, message_id)
  local cached = render_state:get_message(message_id)
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
  render_state:remove_message(message_id)
end

---Append a message header to the buffer.
---@param render_state RenderState
---@param formatter table formatter module
---@param message OpencodeMessage
function M.add_message(render_state, formatter, message)
  local header_data = formatter.format_message_header(message)
  local range = M.write(render_state, header_data)
  if range then
    render_state:set_message(message, range.line_start, range.line_end)
  end
end

---Replace an existing message header in the buffer.
---@param render_state RenderState
---@param message_id string
---@param formatted_data Output
---@return boolean success
function M.replace_message(render_state, message_id, formatted_data)
  local cached = render_state:get_message(message_id)
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

  render_state:set_message(cached.message, cached.line_start, new_line_end)

  local delta = new_line_end - old_line_end
  if delta ~= 0 then
    render_state:shift_all(old_line_end + 1, delta)
  end

  return true
end

---Compute the buffer line at which `part_id` should be inserted.
---
---Returns the line after the nearest preceding sibling that has already been
---rendered, or the line after the message header if no sibling is rendered yet.
---
---@param render_state RenderState
---@param part_id string
---@param message_id string
---@return integer? insertion_line 1-indexed, or nil on error.
function M._insertion_point(render_state, part_id, message_id)
  local rendered_message = render_state:get_message(message_id)
  if not rendered_message or not rendered_message.message then
    return nil
  end

  local message = rendered_message.message
  local fallback = rendered_message.line_end and (rendered_message.line_end + 1)
  if not fallback then
    return nil
  end

  local current_index = nil
  if message.parts then
    for i, part in ipairs(message.parts) do
      if part.id == part_id then
        current_index = i
        break
      end
    end
  end

  if not current_index then
    return fallback
  end

  for i = current_index - 1, 1, -1 do
    local prev_part = message.parts[i]
    if prev_part and prev_part.id then
      local prev_rendered = render_state:get_part(prev_part.id)
      if prev_rendered and prev_rendered.line_end then
        return prev_rendered.line_end + 1
      end
    end
  end

  return fallback
end

return M
