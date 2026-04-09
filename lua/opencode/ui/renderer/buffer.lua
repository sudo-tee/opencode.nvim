local ctx = require('opencode.ui.renderer.ctx')
local state = require('opencode.state')
local output_window = require('opencode.ui.output_window')

local M = {}

local pinned_bottom_message_ids = {
  ['permission-display-message'] = true,
  ['question-display-message'] = true,
}

---@param message_id string|nil
---@return boolean
local function is_pinned_bottom_message(message_id)
  return message_id ~= nil and pinned_bottom_message_ids[message_id] == true
end

---@param extmarks table<number, OutputExtmark[]|fun(): OutputExtmark>[]|table<number, OutputExtmark[]>|nil
---@return boolean
local function has_extmarks(extmarks)
  return type(extmarks) == 'table' and next(extmarks) ~= nil
end

---@param extmarks table<number, OutputExtmark[]>
---@param line_start integer
local function accumulate_bulk_extmarks(extmarks, line_start)
  for line_idx, marks in pairs(extmarks) do
    local actual_line = line_start + line_idx
    local bucket = ctx.bulk_extmarks_by_line[actual_line]
    if not bucket then
      bucket = {}
      ctx.bulk_extmarks_by_line[actual_line] = bucket
    end
    for _, mark in ipairs(marks) do
      local copy = vim.deepcopy(mark)
      if copy.end_row then
        copy.end_row = line_start + copy.end_row
      end
      bucket[#bucket + 1] = copy
    end
  end
end

---@param actions OutputAction[]|nil
---@return boolean
local function has_actions(actions)
  return type(actions) == 'table' and #actions > 0
end

---@param previous_formatted Output|nil
---@param formatted_data Output
---@return integer
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

---@param lines string[]|nil
---@param start_idx integer
---@return string[]
local function slice_lines(lines, start_idx)
  local slice = {}
  for i = start_idx, #(lines or {}) do
    slice[#slice + 1] = lines[i]
  end
  return slice
end

---@param extmarks table<number, OutputExtmark[]>|nil
---@param start_line integer
---@return table<number, OutputExtmark[]>
local function slice_extmarks(extmarks, start_line)
  local slice = {}
  for line_idx, marks in pairs(extmarks or {}) do
    if line_idx < 0 then
      slice[line_idx] = vim.deepcopy(marks)
    elseif line_idx >= start_line then
      slice[line_idx - start_line] = vim.deepcopy(marks)
    end
  end
  return slice
end

---@param mark OutputExtmark|fun(): OutputExtmark
---@return OutputExtmark
local function resolve_mark(mark)
  return type(mark) == 'function' and mark() or mark
end

---@param a (OutputExtmark|fun(): OutputExtmark)[]|nil
---@param b (OutputExtmark|fun(): OutputExtmark)[]|nil
---@return boolean
local function marks_equal(a, b)
  a = a or {}
  b = b or {}

  if #a ~= #b then
    return false
  end

  for i = 1, #a do
    if not vim.deep_equal(resolve_mark(a[i]), resolve_mark(b[i])) then
      return false
    end
  end

  return true
end

---@param previous_formatted Output|nil
---@param formatted_data Output
---@return integer
local function unchanged_extmark_prefix_len(previous_formatted, formatted_data)
  local previous_extmarks = previous_formatted and previous_formatted.extmarks or {}
  local next_extmarks = formatted_data and formatted_data.extmarks or {}

  for line_idx, _ in pairs(previous_extmarks) do
    if line_idx < 0 and not marks_equal(previous_extmarks[line_idx], next_extmarks[line_idx]) then
      return 0
    end
  end

  for line_idx, _ in pairs(next_extmarks) do
    if line_idx < 0 and not marks_equal(previous_extmarks[line_idx], next_extmarks[line_idx]) then
      return 0
    end
  end

  local previous_lines = previous_formatted and previous_formatted.lines or {}
  local next_lines = formatted_data and formatted_data.lines or {}
  local max_lines = math.max(#previous_lines, #next_lines)
  local prefix_len = 0

  for line_idx = 0, math.max(max_lines - 1, 0) do
    local previous_marks = previous_formatted and previous_formatted.extmarks and previous_formatted.extmarks[line_idx]
      or nil
    local next_marks = formatted_data and formatted_data.extmarks and formatted_data.extmarks[line_idx] or nil

    if not marks_equal(previous_marks, next_marks) then
      break
    end

    prefix_len = line_idx + 1
  end

  return prefix_len
end

---@param start_line integer
---@param lines string[]
local function highlight_written_lines(start_line, lines)
  if #lines == 0 then
    return
  end
  output_window.highlight_changed_lines(start_line, start_line + #lines - 1)
end

---@param previous_formatted Output|nil
---@param formatted_data Output
---@param line_start integer
---@param old_line_end integer
---@param new_line_end integer
---@return integer clear_start
---@return integer clear_end
local function extmark_clear_range(previous_formatted, formatted_data, line_start, old_line_end, new_line_end)
  local prefix_len = math.min(
    unchanged_prefix_len(previous_formatted, formatted_data),
    unchanged_extmark_prefix_len(previous_formatted, formatted_data)
  )

  ---@param formatted Output|nil
  ---@return integer|nil
  local function min_extmark_line(formatted)
    local min_line = nil
    for line_idx in pairs(formatted and formatted.extmarks or {}) do
      if min_line == nil or line_idx < min_line then
        min_line = line_idx
      end
    end
    return min_line
  end

  ---@param formatted Output|nil
  ---@param fallback integer
  ---@return integer
  local function max_extmark_line(formatted, fallback)
    local max_line = fallback
    for line_idx in pairs(formatted and formatted.extmarks or {}) do
      max_line = math.max(max_line, line_start + line_idx)
    end
    return max_line
  end

  local clear_start = line_start + prefix_len
  local previous_min_extmark = min_extmark_line(previous_formatted)
  local next_min_extmark = min_extmark_line(formatted_data)
  if previous_min_extmark ~= nil then
    clear_start = math.min(clear_start, line_start + previous_min_extmark)
  end
  if next_min_extmark ~= nil then
    clear_start = math.min(clear_start, line_start + next_min_extmark)
  end

  clear_start = math.max(0, clear_start)
  local clear_end = math.max(
    max_extmark_line(previous_formatted, old_line_end),
    max_extmark_line(formatted_data, new_line_end)
  ) + 1

  return clear_start, clear_end
end

---@param previous_formatted Output|nil
---@param formatted_data Output
---@param line_start integer
---@param old_line_end integer
---@param new_line_end integer
---@param skip_clear? boolean
local function apply_extmarks(previous_formatted, formatted_data, line_start, old_line_end, new_line_end, skip_clear)
  local clear_start, clear_end = extmark_clear_range(previous_formatted, formatted_data, line_start, old_line_end, new_line_end)
  if not skip_clear then
    output_window.clear_extmarks(clear_start, clear_end)
  end

  local extmark_start_line = math.max(0, clear_start - line_start)
  local extmarks = slice_extmarks(formatted_data.extmarks, extmark_start_line)
  if has_extmarks(extmarks) then
    output_window.set_extmarks(extmarks, clear_start)
  end
end

---@param message_id string
---@return integer
local function get_message_insert_line(message_id)
  local rendered_message = ctx.render_state:get_message(message_id)
  if rendered_message and rendered_message.line_start then
    return rendered_message.line_start
  end

  local line_count = output_window.get_buf_line_count()
  local append_at = math.max(line_count - 1, 0)
  if line_count == 1 then
    local windows = state.windows
    local output_buf = windows and windows.output_buf
    if output_buf and vim.api.nvim_buf_is_valid(output_buf) then
      local lines = vim.api.nvim_buf_get_lines(output_buf, 0, 1, false)
      if lines[1] == '' then
        return 0
      end
    end
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
    if is_pinned_bottom_message(message_id) then
      return append_at
    end

    for _, pinned_message_id in ipairs({ 'permission-display-message', 'question-display-message' }) do
      local pinned_rendered = ctx.render_state:get_message(pinned_message_id)
      if pinned_rendered and pinned_rendered.line_start then
        return pinned_rendered.line_start
      end
    end

    return append_at
  end

  if is_pinned_bottom_message(message_id) then
    return append_at
  end

  for i = message_index + 1, #messages do
    local next_message = messages[i]
    if next_message and next_message.info and next_message.info.id then
      if is_pinned_bottom_message(next_message.info.id) then
        local next_rendered = ctx.render_state:get_message(next_message.info.id)
        if next_rendered and next_rendered.line_start then
          return next_rendered.line_start
        end
      end

      local next_rendered = ctx.render_state:get_message(next_message.info.id)
      if next_rendered and next_rendered.line_start then
        return next_rendered.line_start
      end
    end
  end

  for _, pinned_message_id in ipairs({ 'permission-display-message', 'question-display-message' }) do
    local pinned_rendered = ctx.render_state:get_message(pinned_message_id)
    if pinned_rendered and pinned_rendered.line_start then
      return pinned_rendered.line_start
    end
  end

  return append_at
end

---@param part_id string
---@param message_id string
---@return integer|nil
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

---@param lines string[]
---@param start_line integer
---@param end_line integer
---@return { line_start: integer, line_end: integer }
local function write_at(lines, start_line, end_line)
  output_window.set_lines(lines, start_line, end_line)
  highlight_written_lines(start_line, lines)
  return {
    line_start = start_line,
    line_end = start_line + #lines - 1,
  }
end

---@param part_id string
---@param formatted_data Output
---@param line_start integer
local function apply_part_actions(part_id, formatted_data, line_start)
  if has_actions(formatted_data.actions) then
    ctx.render_state:clear_actions(part_id)
    ctx.render_state:add_actions(part_id, vim.deepcopy(formatted_data.actions), line_start)
  else
    ctx.render_state:clear_actions(part_id)
  end

  local part_data = ctx.render_state:get_part(part_id)
  if part_data then
    part_data.has_extmarks = has_extmarks(formatted_data.extmarks)
  end
end

---@param part_id string
---@param formatted_data Output
local function set_part_extmark_state(part_id, formatted_data)
  local part_data = ctx.render_state:get_part(part_id)
  if part_data then
    part_data.has_extmarks = has_extmarks(formatted_data.extmarks)
  end
end

---@param message OpencodeMessage|nil
---@return string|nil
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

---@param message OpencodeMessage|nil
---@return string|nil
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

---@param call_id string
---@param message_id string
---@return string|nil
function M.find_part_by_call_id(call_id, message_id)
  return ctx.render_state:get_part_by_call_id(call_id, message_id)
end

---@param message_id string
---@param formatted_data Output
---@param previous_formatted Output|nil
---@return boolean
function M.upsert_message_now(message_id, formatted_data, previous_formatted)
  if ctx.bulk_mode then
    local line_start = #ctx.bulk_buffer_lines
    local line_end = line_start + #formatted_data.lines - 1

    for _, line in ipairs(formatted_data.lines) do
      ctx.bulk_buffer_lines[#ctx.bulk_buffer_lines + 1] = line
    end
    if has_extmarks(formatted_data.extmarks) then
      accumulate_bulk_extmarks(formatted_data.extmarks, line_start)
    end

    local message_data = ctx.render_state:get_message(message_id)
    if message_data then
      ctx.render_state:set_message(message_data.message, line_start, line_end)
    end

    return true
  end

  local cached = ctx.render_state:get_message(message_id)
  if cached and cached.line_start and cached.line_end then
    local old_line_end = cached.line_end
    local prefix_len = unchanged_prefix_len(previous_formatted, formatted_data)
    local write_start = cached.line_start + prefix_len
    local lines_to_write = slice_lines(formatted_data.lines, prefix_len + 1)
    local clear_start, clear_end = extmark_clear_range(
      previous_formatted,
      formatted_data,
      cached.line_start,
      old_line_end,
      cached.line_start + #formatted_data.lines - 1
    )

    output_window.clear_extmarks(clear_start, clear_end)
    output_window.set_lines(lines_to_write, write_start, cached.line_end + 1)
    highlight_written_lines(write_start, lines_to_write)

    local new_line_end = cached.line_start + #formatted_data.lines - 1
    apply_extmarks(previous_formatted, formatted_data, cached.line_start, old_line_end, new_line_end, true)
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

---@param part_id string
---@param message_id string
---@param formatted_data Output
---@param previous_formatted Output|nil
---@return boolean
function M.upsert_part_now(part_id, message_id, formatted_data, previous_formatted)
  if ctx.bulk_mode then
    local line_start = #ctx.bulk_buffer_lines
    local line_end = line_start + #formatted_data.lines - 1

    for _, line in ipairs(formatted_data.lines) do
      ctx.bulk_buffer_lines[#ctx.bulk_buffer_lines + 1] = line
    end
    if has_extmarks(formatted_data.extmarks) then
      accumulate_bulk_extmarks(formatted_data.extmarks, line_start)
    end

    local part_data = ctx.render_state:get_part(part_id)
    if part_data then
      ctx.render_state:set_part(part_data.part, line_start, line_end)
      apply_part_actions(part_id, formatted_data, line_start)
    end

    return true
  end

  local cached = ctx.render_state:get_part(part_id)
  if cached and cached.line_start and cached.line_end then
    local old_line_end = cached.line_end
    local prefix_len = unchanged_prefix_len(previous_formatted, formatted_data)
    local write_start = cached.line_start + prefix_len
    local lines_to_write = slice_lines(formatted_data.lines, prefix_len + 1)
    local clear_start, clear_end = extmark_clear_range(
      previous_formatted,
      formatted_data,
      cached.line_start,
      old_line_end,
      cached.line_start + #formatted_data.lines - 1
    )

    output_window.clear_extmarks(clear_start, clear_end)
    output_window.set_lines(lines_to_write, write_start, cached.line_end + 1)
    highlight_written_lines(write_start, lines_to_write)

    local new_line_end = cached.line_start + #formatted_data.lines - 1
    apply_part_actions(part_id, formatted_data, cached.line_start)

    if new_line_end ~= cached.line_end then
      ctx.render_state:update_part_lines(part_id, cached.line_start, new_line_end)
    end
    apply_extmarks(previous_formatted, formatted_data, cached.line_start, old_line_end, new_line_end, true)
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

---@param part_id string
---@param extra_lines string[]
---@param extra_extmarks table<number, OutputExtmark[]>|nil
---@param previous_formatted Output|nil
---@return boolean
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

---@param part_id string
function M.remove_part_now(part_id)
  if ctx.bulk_mode then
    -- In bulk mode, we don't actually remove from buffer since we're building fresh
    -- Just track that this part should be excluded
    ctx.render_state:remove_part(part_id)
    return
  end

  local cached = ctx.render_state:get_part(part_id)
  if not cached or not cached.line_start or not cached.line_end then
    ctx.render_state:remove_part(part_id)
    return
  end

  output_window.clear_extmarks(cached.line_start - 1, cached.line_end + 1)
  output_window.set_lines({}, cached.line_start, cached.line_end + 1)
  ctx.render_state:remove_part(part_id)
end

---@param message_id string
function M.remove_message_now(message_id)
  if ctx.bulk_mode then
    -- In bulk mode, we don't actually remove from buffer since we're building fresh
    -- Just track that this message should be excluded
    ctx.render_state:remove_message(message_id)
    return
  end

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
