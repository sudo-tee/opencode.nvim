---@class MessageMap
---@field _message_lookup table<string, integer>
---@field _part_lookup table<string, {message_idx: integer, part_idx: integer}>
---@field _call_id_lookup table<string, string>
local MessageMap = {}
MessageMap.__index = MessageMap

---@return MessageMap
function MessageMap.new()
  local self = setmetatable({}, MessageMap)
  self:reset()
  return self
end

function MessageMap:reset()
  self._message_lookup = {} -- message_id -> message_index
  self._part_lookup = {} -- part_id -> {message_idx, part_idx}
  self._call_id_lookup = {} -- call_id -> part_id
end

---Hydrate lookup tables from existing messages array
---@param messages OpencodeMessage[] Messages array to build lookups from
function MessageMap:hydrate(messages)
  self:reset()

  for msg_idx, msg_wrapper in ipairs(messages) do
    if msg_wrapper.info and msg_wrapper.info.id then
      self:add_message(msg_wrapper.info.id, msg_idx)
    end

    if msg_wrapper.parts then
      for part_idx, part in ipairs(msg_wrapper.parts) do
        if part.id then
          self:add_part(part.id, msg_idx, part_idx, part.callID)
        end
      end
    end
  end
end

---Add message to lookup table
---@param message_id string Message ID
---@param message_idx integer Message index
function MessageMap:add_message(message_id, message_idx)
  self._message_lookup[message_id] = message_idx
end

---Remove message from lookup table and remove from messages array automatically
---Also removes all parts belonging to this message
---@param message_id string Message ID
---@param messages table[] Messages array to modify
function MessageMap:remove_message(message_id, messages)
  local message_idx = self._message_lookup[message_id]
  if not message_idx or not messages then
    return
  end

  local msg_wrapper = messages[message_idx]

  if msg_wrapper and msg_wrapper.parts then
    for _, part in ipairs(msg_wrapper.parts) do
      if part.id then
        self._part_lookup[part.id] = nil
        if part.callID then
          self._call_id_lookup[part.callID] = nil
        end
      end
    end
  end

  table.remove(messages, message_idx)

  self._message_lookup[message_id] = nil

  self:update_indices_after_removal(message_idx)
end

---Add part to lookup tables with call_id support
---@param part_id string Part ID
---@param message_idx integer Message index
---@param part_idx integer Part index
---@param call_id? string Optional call ID for permission handling
function MessageMap:add_part(part_id, message_idx, part_idx, call_id)
  self._part_lookup[part_id] = { message_idx = message_idx, part_idx = part_idx }
  if call_id then
    self._call_id_lookup[call_id] = part_id
  end
end

---Update call ID mapping for a part
---@param call_id string Call ID
---@param part_id string Part ID
function MessageMap:update_call_id(call_id, part_id)
  self._call_id_lookup[call_id] = part_id
end

---Update existing part in messages array using lookup
---@param part_id string Part ID
---@param new_part table New part data
---@param messages table[] Messages array to modify
---@return integer? part_idx Part index if successful, nil otherwise
function MessageMap:update_part(part_id, new_part, messages)
  local location = self._part_lookup[part_id]
  if not location or not messages then
    return nil
  end

  local msg_wrapper = messages[location.message_idx]
  if not msg_wrapper or not msg_wrapper.parts then
    return nil
  end

  msg_wrapper.parts[location.part_idx] = new_part

  if new_part.callID then
    self._call_id_lookup[new_part.callID] = part_id
  end

  return location.part_idx
end

---Remove part from lookup tables and remove from messages array automatically
---@param part_id string Part ID
---@param call_id? string Optional call ID to remove
---@param messages table[] Messages array to modify
function MessageMap:remove_part(part_id, call_id, messages)
  local location = self._part_lookup[part_id]
  if not location or not messages then
    return
  end

  local msg_wrapper = messages[location.message_idx]
  if not msg_wrapper or not msg_wrapper.parts then
    return
  end

  table.remove(msg_wrapper.parts, location.part_idx)

  self._part_lookup[part_id] = nil
  if call_id then
    self._call_id_lookup[call_id] = nil
  end

  for other_part_id, other_location in pairs(self._part_lookup) do
    if other_location.message_idx == location.message_idx and other_location.part_idx > location.part_idx then
      other_location.part_idx = other_location.part_idx - 1
    end
  end
end

---Update message indices after a message is removed
---@param removed_idx integer Index of removed message
function MessageMap:update_indices_after_removal(removed_idx)
  for message_id, idx in pairs(self._message_lookup) do
    if idx > removed_idx then
      self._message_lookup[message_id] = idx - 1
    end
  end

  for part_id, location in pairs(self._part_lookup) do
    if location.message_idx > removed_idx then
      location.message_idx = location.message_idx - 1
    end
  end
end

---Update part indices after a part is removed from a message
---@param message_idx integer Message index
---@param removed_part_idx integer Index of removed part
---@param remaining_parts table[] Remaining parts in the message
function MessageMap:update_part_indices_after_removal(message_idx, removed_part_idx, remaining_parts)
  for i = removed_part_idx, #remaining_parts do
    local remaining_part = remaining_parts[i]
    if remaining_part and remaining_part.id then
      local location = self._part_lookup[remaining_part.id]
      if location then
        location.part_idx = i
      end
    end
  end
end

---Update message indices after a message is removed
---@param removed_idx integer Index of removed message
function MessageMap:update_message_indices_after_removal(removed_idx)
  return self:update_indices_after_removal(removed_idx)
end

---Get message index by ID
---@param message_id string Message ID
---@return integer? message_idx Message index if found, nil otherwise
function MessageMap:get_message_index(message_id)
  return self._message_lookup[message_id]
end

---Get part location by ID
---@param part_id string Part ID
---@return {message_idx: integer, part_idx: integer}? location Part location if found, nil otherwise
function MessageMap:get_part_location(part_id)
  return self._part_lookup[part_id]
end

---Get part ID by call ID
---@param call_id string Call ID
---@return string? part_id Part ID if found, nil otherwise
function MessageMap:get_part_id_by_call_id(call_id)
  return self._call_id_lookup[call_id]
end

---Check if part exists in lookup
---@param part_id string Part ID
---@return boolean
function MessageMap:has_part(part_id)
  return self._part_lookup[part_id] ~= nil
end

---Get message wrapper and index by ID using lookup table
---@param message_id string Message ID
---@param messages table[] Array of messages
---@return table? msg_wrapper, integer? msg_idx
function MessageMap:get_message_by_id(message_id, messages)
  local msg_idx = self:get_message_index(message_id)
  if not msg_idx or not messages[msg_idx] then
    return nil, nil
  end
  return messages[msg_idx], msg_idx
end

---Get part, message wrapper, and indices by part ID using lookup table
---@param part_id string Part ID
---@param messages table[] Array of messages
---@return table? part, table? msg_wrapper, integer? msg_idx, integer? part_idx
function MessageMap:get_part_by_id(part_id, messages)
  local location = self:get_part_location(part_id)
  if not location then
    return nil, nil, nil, nil
  end

  local msg_wrapper = messages[location.message_idx]
  if not msg_wrapper or not msg_wrapper.parts or not msg_wrapper.parts[location.part_idx] then
    return nil, nil, nil, nil
  end

  return msg_wrapper.parts[location.part_idx], msg_wrapper, location.message_idx, location.part_idx
end

return MessageMap
