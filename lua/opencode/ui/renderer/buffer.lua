local ctx = require('opencode.ui.renderer.ctx')
local state = require('opencode.state')
local output_window = require('opencode.ui.output_window')

local M = {}

local function has_extmarks(extmarks)
  return type(extmarks) == 'table' and next(extmarks) ~= nil
end

local function has_actions(actions)
  return type(actions) == 'table' and #actions > 0
end

local function unchanged_prefix_len(previous_formatted, formatted_data)
  local previous_lines = previous_formatted and previous_formatted.lines or {}
  local next_lines = formatted_data and formatted_data.lines or {}
  local prefix_len = 0

  for i = 1, math.min(#previous_lines, #next_lines) do
    if previous_lines[i] ~= next_lines[i] then
      break
    end
    prefix_len = i
  end

  return prefix_len
end

local function slice_lines(lines, start_idx)
  local slice = {}
  for i = start_idx, #(lines or {}) do
    slice[#slice + 1] = lines[i]
  end
  return slice
end

local function slice_extmarks(extmarks, start_line)
  local slice = {}
  for line_idx, marks in pairs(extmarks or {}) do
    if line_idx >= start_line + 1 then
      slice[line_idx - start_line] = vim.deepcopy(marks)
    end
  end
  return slice
end

local function highlight_written_lines(start_line, lines)
  if #lines == 0 then
    return
  end
  output_window.highlight_changed_lines(start_line, start_line + #lines - 1)
end

local function apply_extmarks(previous_formatted, formatted_data, line_start, old_line_end, new_line_end)
  local prefix_len = unchanged_prefix_len(previous_formatted, formatted_data)
  local clear_start = line_start + prefix_len
  local clear_end = math.max(old_line_end, new_line_end) + 1

  output_window.clear_extmarks(clear_start, clear_end)

  local extmarks = slice_extmarks(formatted_data.extmarks, prefix_len)
  if has_extmarks(extmarks) then
    output_window.set_extmarks(extmarks, clear_start)
  end
end

local function get_message_insert_line(message_id)
  local rendered_message = ctx.render_state:get_message(message_id)
  if rendered_message and rendered_message.line_start then
    return rendered_message.line_start
  end

  local messages = state.messages or {}
  local message_index = nil
  for i, message in ipairs(messages) do
    if message.info and message.info.id == message_id then
      message_index = i
      break
    end
  end

  if not message_index then
    return output_window.get_buf_line_count()
  end

  for i = message_index + 1, #messages do
    local next_message = messages[i]
    if next_message and next_message.info and next_message.info.id then
      local next_rendered = ctx.render_state:get_message(next_message.info.id)
      if next_rendered and next_rendered.line_start then
        return next_rendered.line_start
      end
    end
  end

  return output_window.get_buf_line_count()
end

local function get_part_insertion_line(part_id, message_id)
  local rendered_message = ctx.render_state:get_message(message_id)
  if not rendered_message or not rendered_message.message or not rendered_message.line_end then
    return nil
  end

  local message = rendered_message.message
  local insertion_line = rendered_message.line_end + 1
  local current_part_index = nil

  for i, part in ipairs(message.parts or {}) do
    if part.id == part_id then
      current_part_index = i
      break
    end
  end

  if not current_part_index then
    return insertion_line
  end

  for i = current_part_index - 1, 1, -1 do
    local previous = message.parts[i]
    if previous and previous.id then
      local previous_rendered = ctx.render_state:get_part(previous.id)
      if previous_rendered and previous_rendered.line_end then
        return previous_rendered.line_end + 1
      end
    end
  end

  return insertion_line
end

local function write_at(lines, start_line, end_line)
  output_window.set_lines(lines, start_line, end_line)
  highlight_written_lines(start_line, lines)
  return {
    line_start = start_line,
    line_end = start_line + #lines - 1,
  }
end

local function apply_part_actions(part_id, formatted_data, line_start)
  if has_actions(formatted_data.actions) then
    ctx.render_state:clear_actions(part_id)
    ctx.render_state:add_actions(part_id, vim.deepcopy(formatted_data.actions), line_start + 1)
  else
    ctx.render_state:clear_actions(part_id)
  end

  local part_data = ctx.render_state:get_part(part_id)
  if part_data then
    part_data.has_extmarks = has_extmarks(formatted_data.extmarks)
  end
end

local function set_part_extmark_state(part_id, formatted_data)
  local part_data = ctx.render_state:get_part(part_id)
  if part_data then
    part_data.has_extmarks = has_extmarks(formatted_data.extmarks)
  end
end

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

function M.find_part_by_call_id(call_id, message_id)
  return ctx.render_state:get_part_by_call_id(call_id, message_id)
end

function M.upsert_message_now(message_id, formatted_data, previous_formatted)
  local cached = ctx.render_state:get_message(message_id)
  if cached and cached.line_start and cached.line_end then
    local old_line_end = cached.line_end
    local prefix_len = unchanged_prefix_len(previous_formatted, formatted_data)
    local write_start = cached.line_start + prefix_len
    local lines_to_write = slice_lines(formatted_data.lines, prefix_len + 1)

    output_window.set_lines(lines_to_write, write_start, cached.line_end + 1)
    highlight_written_lines(write_start, lines_to_write)

    local new_line_end = cached.line_start + #formatted_data.lines - 1
    apply_extmarks(previous_formatted, formatted_data, cached.line_start, old_line_end, new_line_end)
    ctx.render_state:set_message(cached.message, cached.line_start, new_line_end)

    local delta = new_line_end - old_line_end
    if delta ~= 0 then
      ctx.render_state:shift_all(old_line_end + 1, delta)
    end
    return true
  end

  local insert_at = get_message_insert_line(message_id)
  local message_data = ctx.render_state:get_message(message_id)
  if message_data and message_data.message then
    local range = write_at(formatted_data.lines, insert_at, insert_at)
    if has_extmarks(formatted_data.extmarks) then
      output_window.set_extmarks(formatted_data.extmarks, insert_at)
    end

    ctx.render_state:shift_all(insert_at, #formatted_data.lines)
    ctx.render_state:set_message(message_data.message, range.line_start, range.line_end)
    return true
  end

  return false
end

function M.upsert_part_now(part_id, message_id, formatted_data, previous_formatted)
  local cached = ctx.render_state:get_part(part_id)
  if cached and cached.line_start and cached.line_end then
    local old_line_end = cached.line_end
    local prefix_len = unchanged_prefix_len(previous_formatted, formatted_data)
    local write_start = cached.line_start + prefix_len
    local lines_to_write = slice_lines(formatted_data.lines, prefix_len + 1)

    output_window.set_lines(lines_to_write, write_start, cached.line_end + 1)
    highlight_written_lines(write_start, lines_to_write)

    local new_line_end = cached.line_start + #formatted_data.lines - 1
    apply_part_actions(part_id, formatted_data, cached.line_start)

    if new_line_end ~= cached.line_end then
      ctx.render_state:update_part_lines(part_id, cached.line_start, new_line_end)
    end
    apply_extmarks(previous_formatted, formatted_data, cached.line_start, old_line_end, new_line_end)
    set_part_extmark_state(part_id, formatted_data)
    return true
  end

  local insert_at = get_part_insertion_line(part_id, message_id)
  if not insert_at then
    return false
  end

  local part_data = ctx.render_state:get_part(part_id)
  if part_data and part_data.part then
    local range = write_at(formatted_data.lines, insert_at, insert_at)
    ctx.render_state:shift_all(insert_at, #formatted_data.lines)
    ctx.render_state:set_part(part_data.part, range.line_start, range.line_end)
    apply_part_actions(part_id, formatted_data, range.line_start)
    if has_extmarks(formatted_data.extmarks) then
      output_window.set_extmarks(formatted_data.extmarks, range.line_start)
    end
    set_part_extmark_state(part_id, formatted_data)
    return true
  end

  return false
end

function M.append_part_now(part_id, extra_lines, extra_extmarks, previous_formatted)
  local cached = ctx.render_state:get_part(part_id)
  if not cached or not cached.line_start or not cached.line_end or #extra_lines == 0 then
    return false
  end

  local insert_at = cached.line_end + 1
  local old_line_end = cached.line_end
  output_window.set_lines(extra_lines, insert_at, insert_at)
  highlight_written_lines(insert_at, extra_lines)

  local new_line_end = cached.line_end + #extra_lines
  ctx.render_state:update_part_lines(part_id, cached.line_start, new_line_end)

  local formatted_data = ctx.formatted_parts[part_id]
  if formatted_data then
    apply_part_actions(part_id, formatted_data, cached.line_start)
    apply_extmarks(previous_formatted, formatted_data, cached.line_start, old_line_end, new_line_end)
    set_part_extmark_state(part_id, formatted_data)
  elseif has_extmarks(extra_extmarks) then
    output_window.set_extmarks(extra_extmarks, insert_at)
  end

  return true
end

function M.write_formatted_data(formatted_data)
  local new_lines = formatted_data.lines or {}
  if #new_lines == 0 then
    return nil
  end

  local target_line = output_window.get_buf_line_count()
  target_line = target_line - 1
  local append_lines = table.move(new_lines, 1, #new_lines, 1, {})
  append_lines[#append_lines + 1] = ''
  output_window.set_lines(append_lines, target_line)

  if has_extmarks(formatted_data.extmarks) then
    output_window.set_extmarks(formatted_data.extmarks, target_line)
  end

  return {
    line_start = target_line,
    line_end = target_line + #new_lines - 1,
  }
end

function M.remove_part_now(part_id)
  local cached = ctx.render_state:get_part(part_id)
  if not cached or not cached.line_start or not cached.line_end then
    ctx.render_state:remove_part(part_id)
    return
  end

  output_window.clear_extmarks(cached.line_start - 1, cached.line_end + 1)
  output_window.set_lines({}, cached.line_start, cached.line_end + 1)
  ctx.render_state:remove_part(part_id)
end

function M.remove_message_now(message_id)
  local cached = ctx.render_state:get_message(message_id)
  if not cached or not cached.line_start or not cached.line_end then
    ctx.render_state:remove_message(message_id)
    return
  end

  output_window.clear_extmarks(cached.line_start, cached.line_end + 1)
  output_window.set_lines({}, cached.line_start, cached.line_end + 1)
  ctx.render_state:remove_message(message_id)
end

return M
