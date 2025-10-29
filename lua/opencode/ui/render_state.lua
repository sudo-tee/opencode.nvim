local state = require('opencode.state')

---@class RenderedMessage
---@field message OpencodeMessage Direct reference to message in state.messages
---@field line_start integer? Line where message header starts
---@field line_end integer? Line where message header ends

---@class RenderedPart
---@field part OpencodeMessagePart Direct reference to part in state.messages
---@field message_id string ID of parent message
---@field line_start integer? Line where part starts
---@field line_end integer? Line where part ends
---@field actions table[] Actions associated with this part

---@class LineIndex
---@field line_to_part table<integer, string> Maps line number -> part ID
---@field line_to_message table<integer, string> Maps line number -> message ID

---@class RenderState
---@field _messages table<string, RenderedMessage> Message ID -> rendered message
---@field _parts table<string, RenderedPart> Part ID -> rendered part
---@field _line_index LineIndex Line number -> ID mappings
---@field _line_index_valid boolean Whether line index is up to date
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
  self._line_index_valid = false
end

---Get message render data by ID
---@param message_id string Message ID
---@return RenderedMessage?
function RenderState:get_message(message_id)
  return self._messages[message_id]
end

---Get part render data by ID
---@param part_id string Part ID
---@return RenderedPart?
function RenderState:get_part(part_id)
  return self._parts[part_id]
end

---Get part ID by call ID and message ID
---@param call_id string Call ID
---@param message_id string Message ID to check the parts of
---@return string? part_id Part ID if found
function RenderState:get_part_by_call_id(call_id, message_id)
  local rendered_message = self._messages[message_id]
  -- There aren't a lot of parts per message and call_id lookups aren't very common so
  -- a little iteration is fine
  if rendered_message and rendered_message.message and rendered_message.message.parts then
    for _, part in ipairs(rendered_message.message.parts) do
      if part.callID == call_id then
        return part.id
      end
    end
  end
  return nil
end

---Get part ID by snapshot_id and message ID
---@param snapshot_id string Call ID
---@return OpencodeMessagePart? part Part if found
function RenderState:get_part_by_snapshot_id(snapshot_id)
  for _, rendered_message in pairs(self._messages) do
    for _, part in ipairs(rendered_message.message.parts) do
      if part.type == 'patch' and part.hash == snapshot_id then
        return part
      end
    end
  end
  return nil
end

---Ensure line index is up to date
function RenderState:_ensure_line_index()
  if not self._line_index_valid then
    self:_rebuild_line_index()
  end
end

---Get part at specific line
---@param line integer Line number (1-indexed)
---@return RenderedPart?
function RenderState:get_part_at_line(line)
  self:_ensure_line_index()
  local part_id = self._line_index.line_to_part[line]
  if not part_id then
    return nil
  end
  return self._parts[part_id]
end

---Get message at specific line
---@param line integer Line number (1-indexed)
---@return RenderedMessage?
function RenderState:get_message_at_line(line)
  self:_ensure_line_index()
  local message_id = self._line_index.line_to_message[line]
  if not message_id then
    return nil
  end
  return self._messages[message_id]
end

---Get actions at specific line
---@param line integer Line number (1-indexed)
---@return table[] List of actions at that line
function RenderState:get_actions_at_line(line)
  self:_ensure_line_index()
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
---@param message OpencodeMessage Direct reference to message
---@param line_start integer? Line where message header starts
---@param line_end integer? Line where message header ends
function RenderState:set_message(message, line_start, line_end)
  if not message or not message.info or not message.info.id then
    return
  end
  local message_id = message.info.id

  if not self._messages[message_id] then
    self._messages[message_id] = {
      message = message,
      line_start = line_start,
      line_end = line_end,
    }
  else
    local msg_data = self._messages[message_id]
    msg_data.message = message
    if line_start then
      msg_data.line_start = line_start
    end
    if line_end then
      msg_data.line_end = line_end
    end
  end

  if line_start and line_end then
    self._line_index_valid = false
  end
end

---Set or update part render data
---@param part OpencodeMessagePart Direct reference to part (must include id/messageID)
---@param line_start integer? Line where part starts
---@param line_end integer? Line where part ends
function RenderState:set_part(part, line_start, line_end)
  if not part or not part.id or not part.messageID then
    return
  end
  local part_id = part.id
  local message_id = part.messageID

  if not self._parts[part_id] then
    self._parts[part_id] = {
      part = part,
      message_id = message_id,
      line_start = line_start,
      line_end = line_end,
      actions = {},
    }
  else
    local render_part = self._parts[part_id]
    render_part.part = part
    if message_id then
      render_part.message_id = message_id
    end
    if line_start then
      render_part.line_start = line_start
    end
    if line_end then
      render_part.line_end = line_end
    end
  end

  if line_start and line_end then
    self._line_index_valid = false
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

  part_data.line_start = new_line_start
  part_data.line_end = new_line_end

  self._line_index_valid = false

  if delta ~= 0 then
    self:shift_all(old_line_end + 1, delta)
  end

  return true
end

---Update part data reference
---@param part_ref OpencodeMessagePart New part reference (must include id)
---@return RenderedPart? part The rendered part
function RenderState:update_part_data(part_ref)
  if not part_ref or not part_ref.id then
    return
  end
  local rendered_part = self._parts[part_ref.id]
  if not rendered_part then
    return
  end

  rendered_part.part = part_ref
  return rendered_part
end

---Helper to update action line numbers
---@param action table Action to update
---@param delta integer Line offset to apply
local function shift_action_lines(action, delta)
  if action.display_line then
    action.display_line = action.display_line + delta
  end
  if action.range then
    action.range.from = action.range.from + delta
    action.range.to = action.range.to + delta
  end
end

---Add actions to a part
---@param part_id string Part ID
---@param actions table[] Actions to add
---@param offset? integer Optional line offset to apply to actions
function RenderState:add_actions(part_id, actions, offset)
  local part_data = self._parts[part_id]
  if not part_data then
    return
  end

  offset = offset or 0

  for _, action in ipairs(actions) do
    if offset ~= 0 then
      shift_action_lines(action, offset)
    end
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

  self._parts[part_id] = nil
  self._line_index_valid = false

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

  self._messages[message_id] = nil
  self._line_index_valid = false

  self:shift_all(shift_from, -line_count)

  return true
end

---Shift all content starting from a line by delta
---Optimized to scan in reverse order and exit early
---@param from_line integer Line number to start shifting from
---@param delta integer Number of lines to shift (positive or negative)
function RenderState:shift_all(from_line, delta)
  if delta == 0 or not state.messages then
    return
  end

  local found_content_before_from_line = false
  local anything_shifted = false

  for i = #state.messages, 1, -1 do
    local message = state.messages[i] or {}

    local msg_id = message.info and message.info.id
    if msg_id then
      local rendered_msg = self._messages[msg_id]
      if rendered_msg and rendered_msg.line_start and rendered_msg.line_end then
        if rendered_msg.line_start >= from_line then
          rendered_msg.line_start = rendered_msg.line_start + delta
          rendered_msg.line_end = rendered_msg.line_end + delta
          anything_shifted = true
        elseif rendered_msg.line_end < from_line then
          found_content_before_from_line = true
        end
      end
    end

    if message.parts then
      for j = #message.parts, 1, -1 do
        local part = message.parts[j]
        if part.id then
          local rendered_part = self._parts[part.id]
          if rendered_part and rendered_part.line_start and rendered_part.line_end then
            if rendered_part.line_start >= from_line then
              rendered_part.line_start = rendered_part.line_start + delta
              rendered_part.line_end = rendered_part.line_end + delta
              anything_shifted = true

              if rendered_part.actions then
                for _, action in ipairs(rendered_part.actions) do
                  shift_action_lines(action, delta)
                end
              end
            elseif rendered_part.line_end < from_line then
              found_content_before_from_line = true
            end
          end
        end
      end
    end

    if found_content_before_from_line then
      break
    end
  end

  if anything_shifted then
    self._line_index_valid = false
  end
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
  self._line_index_valid = true
end

return RenderState
