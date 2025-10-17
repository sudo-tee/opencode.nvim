local state = require('opencode.state')

---@class MessageRenderData
---@field message_ref OpencodeMessage Direct reference to message in state.messages
---@field line_start integer? Line where message header starts
---@field line_end integer? Line where message header ends

---@class PartRenderData
---@field part_ref MessagePart Direct reference to part in state.messages
---@field message_id string ID of parent message
---@field line_start integer? Line where part starts
---@field line_end integer? Line where part ends
---@field actions table[] Actions associated with this part

---@class LineIndex
---@field line_to_part table<integer, string> Maps line number to part ID
---@field line_to_message table<integer, string> Maps line number to message ID

---@class RenderState
---@field _messages table<string, MessageRenderData> Message ID to render data
---@field _parts table<string, PartRenderData> Part ID to render data
---@field _line_index LineIndex Line number to ID mappings
local RenderState = {}
RenderState.__index = RenderState

---@return RenderState
function RenderState.new()
  local self = setmetatable({}, RenderState)
  self:reset()
  return self
end

function RenderState:reset()
  self._messages = {}
  self._parts = {}
  self._line_index = {
    line_to_part = {},
    line_to_message = {},
  }
end

---Get message render data by ID
---@param message_id string Message ID
---@return MessageRenderData?
function RenderState:get_message(message_id)
  return self._messages[message_id]
end

---Get part render data by ID
---@param part_id string Part ID
---@return PartRenderData?
function RenderState:get_part(part_id)
  return self._parts[part_id]
end

---Get part ID by call ID
---@param call_id string Call ID
---@param message_id? string Optional message ID to limit search scope
---@return string? part_id Part ID if found
function RenderState:get_part_by_call_id(call_id, message_id)
  if message_id then
    local msg_data = self._messages[message_id]
    if msg_data and msg_data.message_ref and msg_data.message_ref.parts then
      for _, part in ipairs(msg_data.message_ref.parts) do
        if part.callID == call_id then
          return part.id
        end
      end
    end
    return nil
  end

  for i = #state.messages, 1, -1 do
    local msg_wrapper = state.messages[i]
    if msg_wrapper.parts then
      for j = #msg_wrapper.parts, 1, -1 do
        local part = msg_wrapper.parts[j]
        if part.callID == call_id then
          return part.id
        end
      end
    end
  end
  return nil
end

---Get part at specific line
---@param line integer Line number (1-indexed)
---@return PartRenderData?, string? part_data, part_id
function RenderState:get_part_at_line(line)
  local part_id = self._line_index.line_to_part[line]
  if not part_id then
    return nil, nil
  end
  return self._parts[part_id], part_id
end

---Get message at specific line
---@param line integer Line number (1-indexed)
---@return MessageRenderData?, string? message_data, message_id
function RenderState:get_message_at_line(line)
  local message_id = self._line_index.line_to_message[line]
  if not message_id then
    return nil, nil
  end
  return self._messages[message_id], message_id
end

---Get actions at specific line
---@param line integer Line number (1-indexed)
---@return table[] List of actions at that line
function RenderState:get_actions_at_line(line)
  local part_id = self._line_index.line_to_part[line]
  if not part_id then
    return {}
  end

  local part_data = self._parts[part_id]
  if not part_data or not part_data.actions then
    return {}
  end

  local actions = {}
  for _, action in ipairs(part_data.actions) do
    if action.range and action.range.from <= line and action.range.to >= line then
      table.insert(actions, action)
    end
  end
  return actions
end

---Set or update message render data
---@param message_id string Message ID
---@param message_ref OpencodeMessage Direct reference to message
---@param line_start integer? Line where message header starts
---@param line_end integer? Line where message header ends
function RenderState:set_message(message_id, message_ref, line_start, line_end)
  if not self._messages[message_id] then
    self._messages[message_id] = {
      message_ref = message_ref,
      line_start = line_start,
      line_end = line_end,
    }
  else
    local msg_data = self._messages[message_id]
    msg_data.message_ref = message_ref
    if line_start then
      msg_data.line_start = line_start
    end
    if line_end then
      msg_data.line_end = line_end
    end
  end

  if line_start and line_end then
    for line = line_start, line_end do
      self._line_index.line_to_message[line] = message_id
    end
  end
end

---Set or update part render data
---@param part_id string Part ID
---@param part_ref MessagePart Direct reference to part
---@param message_id string Parent message ID
---@param line_start integer? Line where part starts
---@param line_end integer? Line where part ends
function RenderState:set_part(part_id, part_ref, message_id, line_start, line_end)
  if not self._parts[part_id] then
    self._parts[part_id] = {
      part_ref = part_ref,
      message_id = message_id,
      line_start = line_start,
      line_end = line_end,
      actions = {},
    }
  else
    local part_data = self._parts[part_id]
    part_data.part_ref = part_ref
    part_data.message_id = message_id
    if line_start then
      part_data.line_start = line_start
    end
    if line_end then
      part_data.line_end = line_end
    end
  end

  if line_start and line_end then
    for line = line_start, line_end do
      self._line_index.line_to_part[line] = part_id
    end
  end
end

---Update part line positions and shift subsequent content
---@param part_id string Part ID
---@param new_line_start integer New start line
---@param new_line_end integer New end line
---@return boolean success
function RenderState:update_part_lines(part_id, new_line_start, new_line_end)
  local part_data = self._parts[part_id]
  if not part_data or not part_data.line_start or not part_data.line_end then
    return false
  end

  local old_line_start = part_data.line_start
  local old_line_end = part_data.line_end
  local old_line_count = old_line_end - old_line_start + 1
  local new_line_count = new_line_end - new_line_start + 1
  local delta = new_line_count - old_line_count

  for line = old_line_start, old_line_end do
    self._line_index.line_to_part[line] = nil
  end

  part_data.line_start = new_line_start
  part_data.line_end = new_line_end

  for line = new_line_start, new_line_end do
    self._line_index.line_to_part[line] = part_id
  end

  if delta ~= 0 then
    self:shift_all(old_line_end + 1, delta)
  end

  return true
end

---Update part data reference
---@param part_id string Part ID
---@param part_ref MessagePart New part reference
---@param text string? New text content
function RenderState:update_part_data(part_id, part_ref, text)
  local part_data = self._parts[part_id]
  if not part_data then
    return
  end

  part_data.part_ref = part_ref
  if text then
    part_data.text = text
  end
end

---Add actions to a part
---@param part_id string Part ID
---@param actions table[] Actions to add
function RenderState:add_actions(part_id, actions)
  local part_data = self._parts[part_id]
  if not part_data then
    return
  end

  for _, action in ipairs(actions) do
    table.insert(part_data.actions, action)
  end
end

---Clear actions for a part
---@param part_id string Part ID
function RenderState:clear_actions(part_id)
  local part_data = self._parts[part_id]
  if not part_data then
    return
  end

  part_data.actions = {}
end

---Get all actions from all parts
---@return table[] List of all actions
function RenderState:get_all_actions()
  local all_actions = {}
  for _, part_data in pairs(self._parts) do
    if part_data.actions then
      for _, action in ipairs(part_data.actions) do
        table.insert(all_actions, action)
      end
    end
  end
  return all_actions
end

---Remove part and shift subsequent content
---@param part_id string Part ID
---@return boolean success
function RenderState:remove_part(part_id)
  local part_data = self._parts[part_id]
  if not part_data or not part_data.line_start or not part_data.line_end then
    return false
  end

  local line_count = part_data.line_end - part_data.line_start + 1
  local shift_from = part_data.line_end + 1

  for line = part_data.line_start, part_data.line_end do
    self._line_index.line_to_part[line] = nil
  end

  self._parts[part_id] = nil

  self:shift_all(shift_from, -line_count)

  return true
end

---Remove message (header only, not parts)
---@param message_id string Message ID
---@return boolean success
function RenderState:remove_message(message_id)
  local msg_data = self._messages[message_id]
  if not msg_data or not msg_data.line_start or not msg_data.line_end then
    return false
  end

  local line_count = msg_data.line_end - msg_data.line_start + 1
  local shift_from = msg_data.line_end + 1

  for line = msg_data.line_start, msg_data.line_end do
    self._line_index.line_to_message[line] = nil
  end

  self._messages[message_id] = nil

  self:shift_all(shift_from, -line_count)

  return true
end

---Shift all content starting from a line by delta
---Optimized to scan in reverse order and exit early
---@param from_line integer Line number to start shifting from
---@param delta integer Number of lines to shift (positive or negative)
function RenderState:shift_all(from_line, delta)
  if delta == 0 then
    return
  end

  local found_content_before_from_line = false

  for i = #state.messages, 1, -1 do
    local msg_wrapper = state.messages[i]

    local msg_id = msg_wrapper.info and msg_wrapper.info.id
    if msg_id then
      local msg_data = self._messages[msg_id]
      if msg_data and msg_data.line_start and msg_data.line_end then
        if msg_data.line_start >= from_line then
          msg_data.line_start = msg_data.line_start + delta
          msg_data.line_end = msg_data.line_end + delta
        elseif msg_data.line_end < from_line then
          found_content_before_from_line = true
        end
      end
    end

    if msg_wrapper.parts then
      for j = #msg_wrapper.parts, 1, -1 do
        local part = msg_wrapper.parts[j]
        if part.id then
          local part_data = self._parts[part.id]
          if part_data and part_data.line_start and part_data.line_end then
            if part_data.line_start >= from_line then
              part_data.line_start = part_data.line_start + delta
              part_data.line_end = part_data.line_end + delta

              if part_data.actions then
                for _, action in ipairs(part_data.actions) do
                  if action.display_line then
                    action.display_line = action.display_line + delta
                  end
                  if action.range then
                    action.range.from = action.range.from + delta
                    action.range.to = action.range.to + delta
                  end
                end
              end
            elseif part_data.line_end < from_line then
              found_content_before_from_line = true
            end
          end
        end
      end
    end

    if found_content_before_from_line then
      self:_rebuild_line_index()
      return
    end
  end

  self:_rebuild_line_index()
end

---Rebuild line index from current state
function RenderState:_rebuild_line_index()
  self._line_index.line_to_part = {}
  self._line_index.line_to_message = {}

  for msg_id, msg_data in pairs(self._messages) do
    if msg_data.line_start and msg_data.line_end then
      for line = msg_data.line_start, msg_data.line_end do
        self._line_index.line_to_message[line] = msg_id
      end
    end
  end

  for part_id, part_data in pairs(self._parts) do
    if part_data.line_start and part_data.line_end then
      for line = part_data.line_start, part_data.line_end do
        self._line_index.line_to_part[line] = part_id
      end
    end
  end
end

return RenderState
