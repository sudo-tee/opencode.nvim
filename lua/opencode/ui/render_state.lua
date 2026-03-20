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
---@field has_extmarks boolean? Whether the part currently has extmarks applied

---@class RenderState
---@field _messages table<string, RenderedMessage> Message ID -> rendered message
---@field _parts table<string, RenderedPart> Part ID -> rendered part
---@field _part_ranges {[1]: integer, [2]: integer, [3]: string}[] Sorted [line_start, line_end, part_id] for binary search
---@field _message_ranges {[1]: integer, [2]: integer, [3]: string}[] Sorted [line_start, line_end, message_id] for binary search
---@field _ranges_valid boolean Whether range arrays are sorted and up-to-date
---@field _max_line_end integer
---@field _max_line_end_valid boolean
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
  self._part_ranges = {}
  self._message_ranges = {}
  self._ranges_valid = false
  self._max_line_end = 0
  self._max_line_end_valid = true
  self._child_session_parts = {}
  self._child_session_parts_index = {} -- session_id -> part_id -> list_index
  self._child_session_task_parts = {}
  self._task_part_child_sessions = {}
  self._snapshot_id_index = {} -- snapshot_id -> OpencodeMessagePart
end

function RenderState:_recompute_max_line_end()
  local max_line_end = 0

  for _, msg_data in pairs(self._messages) do
    if msg_data.line_end and msg_data.line_end > max_line_end then
      max_line_end = msg_data.line_end
    end
  end

  for _, part_data in pairs(self._parts) do
    if part_data.line_end and part_data.line_end > max_line_end then
      max_line_end = part_data.line_end
    end
  end

  self._max_line_end = max_line_end
  self._max_line_end_valid = true
  return max_line_end
end

---@return integer
function RenderState:_get_max_line_end()
  if not self._max_line_end_valid then
    return self:_recompute_max_line_end()
  end
  return self._max_line_end
end

---@param part OpencodeMessagePart?
---@return string?
local function get_child_session_id_for_task_part(part)
  if not part or part.tool ~= 'task' then
    return nil
  end
  local part_state = part.state
  local metadata = part_state and part_state.metadata
  return metadata and metadata.sessionId or nil
end

---@param part_id string
function RenderState:_clear_task_part_child_session(part_id)
  local child_session_id = self._task_part_child_sessions[part_id]
  if not child_session_id then
    return
  end
  if self._child_session_task_parts[child_session_id] == part_id then
    self._child_session_task_parts[child_session_id] = nil
  end
  self._task_part_child_sessions[part_id] = nil
end

---@param part_id string
---@param part OpencodeMessagePart
function RenderState:_index_task_part_child_session(part_id, part)
  self:_clear_task_part_child_session(part_id)
  local child_session_id = get_child_session_id_for_task_part(part)
  if not child_session_id then
    return
  end
  self._child_session_task_parts[child_session_id] = part_id
  self._task_part_child_sessions[part_id] = child_session_id
end

---@param ranges {[1]: integer, [2]: integer, [3]: string}[]
---@param line integer
---@return string?
local function range_lookup(ranges, line)
  local lo, hi = 1, #ranges
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local r = ranges[mid]
    if line < r[1] then
      hi = mid - 1
    elseif line > r[2] then
      lo = mid + 1
    else
      return r[3]
    end
  end
  return nil
end

function RenderState:_rebuild_ranges()
  local part_ranges = {}
  for part_id, part_data in pairs(self._parts) do
    if part_data.line_start and part_data.line_end then
      part_ranges[#part_ranges + 1] = { part_data.line_start, part_data.line_end, part_id }
    end
  end
  table.sort(part_ranges, function(a, b)
    return a[1] < b[1]
  end)
  self._part_ranges = part_ranges

  local msg_ranges = {}
  for msg_id, msg_data in pairs(self._messages) do
    if msg_data.line_start and msg_data.line_end then
      msg_ranges[#msg_ranges + 1] = { msg_data.line_start, msg_data.line_end, msg_id }
    end
  end
  table.sort(msg_ranges, function(a, b)
    return a[1] < b[1]
  end)
  self._message_ranges = msg_ranges

  self._ranges_valid = true
end

function RenderState:_ensure_ranges()
  if not self._ranges_valid then
    self:_rebuild_ranges()
  end
end

---@param session_id string
---@return OpencodeMessagePart[]?
function RenderState:get_child_session_parts(session_id)
  if not session_id then
    return nil
  end
  return self._child_session_parts[session_id]
end

---@param session_id string
---@return string?
function RenderState:get_task_part_by_child_session(session_id)
  if not session_id then
    return nil
  end
  return self._child_session_task_parts[session_id]
end

---@param session_id string
---@param part OpencodeMessagePart
function RenderState:upsert_child_session_part(session_id, part)
  if not session_id or not part or not part.id then
    return
  end

  local session_parts = self._child_session_parts[session_id]
  if not session_parts then
    session_parts = {}
    self._child_session_parts[session_id] = session_parts
    self._child_session_parts_index[session_id] = {}
  end

  local idx = self._child_session_parts_index[session_id][part.id]
  if idx then
    session_parts[idx] = part
  else
    session_parts[#session_parts + 1] = part
    self._child_session_parts_index[session_id][part.id] = #session_parts
  end
end

---@param message_id string
---@return RenderedMessage?
function RenderState:get_message(message_id)
  return self._messages[message_id]
end

---@param line integer 1-indexed
---@return RenderedMessage?
function RenderState:get_message_at_line(line)
  self:_ensure_ranges()
  local msg_id = range_lookup(self._message_ranges, line)
  return msg_id and self._messages[msg_id] or nil
end

---@param part_id string
---@return RenderedPart?
function RenderState:get_part(part_id)
  return self._parts[part_id]
end

---@param line integer 1-indexed
---@return RenderedPart?
function RenderState:get_part_at_line(line)
  self:_ensure_ranges()
  local part_id = range_lookup(self._part_ranges, line)
  return part_id and self._parts[part_id] or nil
end

---@param call_id string
---@param message_id string
---@return string?
function RenderState:get_part_by_call_id(call_id, message_id)
  local rendered_message = self._messages[message_id]
  if rendered_message and rendered_message.message and rendered_message.message.parts then
    for _, part in ipairs(rendered_message.message.parts) do
      if part.callID == call_id then
        return part.id
      end
    end
  end
  return nil
end

---@param snapshot_id string
---@return OpencodeMessagePart?
function RenderState:get_part_by_snapshot_id(snapshot_id)
  return self._snapshot_id_index[snapshot_id]
end

---@param line integer
---@return table[]
function RenderState:get_actions_at_line(line)
  self:_ensure_ranges()
  local part_id = range_lookup(self._part_ranges, line)
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
      actions[#actions + 1] = action
    end
  end
  return actions
end

---@param part_id string
---@param actions table[]
---@param offset? integer Line offset to apply to action line numbers
function RenderState:add_actions(part_id, actions, offset)
  local part_data = self._parts[part_id]
  if not part_data then
    return
  end
  offset = offset or 0
  for _, action in ipairs(actions) do
    if offset ~= 0 then
      if action.display_line then
        action.display_line = action.display_line + offset
      end
      if action.range then
        action.range.from = action.range.from + offset
        action.range.to = action.range.to + offset
      end
    end
    part_data.actions[#part_data.actions + 1] = action
  end
end

---@param part_id string
function RenderState:clear_actions(part_id)
  local part_data = self._parts[part_id]
  if part_data then
    part_data.actions = {}
  end
end

---@return table[]
function RenderState:get_all_actions()
  local all_actions = {}
  for _, part_data in pairs(self._parts) do
    if part_data.actions then
      for _, action in ipairs(part_data.actions) do
        all_actions[#all_actions + 1] = action
      end
    end
  end
  return all_actions
end

---@param message OpencodeMessage
---@param line_start integer?
---@param line_end integer?
function RenderState:set_message(message, line_start, line_end)
  if not message or not message.info or not message.info.id then
    return
  end
  local message_id = message.info.id

  local existing = self._messages[message_id]
  if not existing then
    self._messages[message_id] = {
      message = message,
      line_start = line_start,
      line_end = line_end,
    }
  else
    existing.message = message
    if line_start then
      existing.line_start = line_start
    end
    if line_end then
      existing.line_end = line_end
    end
  end

  if line_start and line_end then
    self._ranges_valid = false
    if self._max_line_end_valid and line_end > self._max_line_end then
      self._max_line_end = line_end
    end
  end
end

---@param part OpencodeMessagePart
---@param line_start integer?
---@param line_end integer?
function RenderState:set_part(part, line_start, line_end)
  if not part or not part.id then
    return
  end
  local part_id = part.id
  local message_id = part.messageID or 'special'

  local existing = self._parts[part_id]
  if not existing then
    self._parts[part_id] = {
      part = part,
      message_id = message_id,
      line_start = line_start,
      line_end = line_end,
      actions = {},
      has_extmarks = false,
    }
  else
    existing.part = part
    if message_id then
      existing.message_id = message_id
    end
    if line_start then
      existing.line_start = line_start
    end
    if line_end then
      existing.line_end = line_end
    end
  end

  if line_start and line_end then
    self._ranges_valid = false
    if self._max_line_end_valid and line_end > self._max_line_end then
      self._max_line_end = line_end
    end
  end

  if part.type == 'patch' and part.hash then
    self._snapshot_id_index[part.hash] = part
  end

  self:_index_task_part_child_session(part_id, part)
end

---@param part_id string
---@param new_line_start integer
---@param new_line_end integer
---@return boolean
function RenderState:update_part_lines(part_id, new_line_start, new_line_end)
  local part_data = self._parts[part_id]
  if not part_data or not part_data.line_start or not part_data.line_end then
    return false
  end

  if part_data.line_start == new_line_start and part_data.line_end == new_line_end then
    return true
  end

  local old_line_end = part_data.line_end
  local old_line_count = old_line_end - part_data.line_start + 1
  local new_line_count = new_line_end - new_line_start + 1
  local delta = new_line_count - old_line_count

  part_data.line_start = new_line_start
  part_data.line_end = new_line_end
  self._ranges_valid = false

  if self._max_line_end_valid then
    if old_line_end == self._max_line_end and new_line_end < old_line_end then
      self._max_line_end_valid = false
    elseif new_line_end > self._max_line_end then
      self._max_line_end = new_line_end
    end
  end

  if delta ~= 0 then
    self:shift_all(old_line_end + 1, delta)
  end

  return true
end

---@param part_ref OpencodeMessagePart
---@return RenderedPart?
function RenderState:update_part_data(part_ref)
  if not part_ref or not part_ref.id then
    return
  end
  local rendered_part = self._parts[part_ref.id]
  if not rendered_part then
    return
  end
  rendered_part.part = part_ref

  if part_ref.type == 'patch' and part_ref.hash then
    self._snapshot_id_index[part_ref.hash] = part_ref
  end

  self:_index_task_part_child_session(part_ref.id, part_ref)
  return rendered_part
end

---@param part_id string
---@return boolean
function RenderState:remove_part(part_id)
  local part_data = self._parts[part_id]
  if not part_data then
    return false
  end

  if part_data.part and part_data.part.type == 'patch' and part_data.part.hash then
    self._snapshot_id_index[part_data.part.hash] = nil
  end

  self:_clear_task_part_child_session(part_id)

  if not part_data.line_start or not part_data.line_end then
    self._parts[part_id] = nil
    return true
  end

  local line_count = part_data.line_end - part_data.line_start + 1
  local shift_from = part_data.line_end + 1

  self._parts[part_id] = nil
  self._ranges_valid = false
  if self._max_line_end_valid and part_data.line_end == self._max_line_end then
    self._max_line_end_valid = false
  end

  self:shift_all(shift_from, -line_count)
  return true
end

---@param message_id string
---@return boolean
function RenderState:remove_message(message_id)
  local msg_data = self._messages[message_id]
  if not msg_data or not msg_data.line_start or not msg_data.line_end then
    return false
  end

  local line_count = msg_data.line_end - msg_data.line_start + 1
  local shift_from = msg_data.line_end + 1

  self._messages[message_id] = nil
  self._ranges_valid = false
  if self._max_line_end_valid and msg_data.line_end == self._max_line_end then
    self._max_line_end_valid = false
  end

  self:shift_all(shift_from, -line_count)
  return true
end

local function shift_action(action, delta)
  if action.display_line then
    action.display_line = action.display_line + delta
  end
  if action.range then
    action.range.from = action.range.from + delta
    action.range.to = action.range.to + delta
  end
end

function RenderState:shift_all(from_line, delta)
  if delta == 0 then
    return
  end

  if from_line > self:_get_max_line_end() then
    return
  end

  local shifted = false

  for _, msg_data in pairs(self._messages) do
    if msg_data.line_start and msg_data.line_start >= from_line then
      msg_data.line_start = msg_data.line_start + delta
      msg_data.line_end = msg_data.line_end + delta
      shifted = true
    end
  end

  for _, part_data in pairs(self._parts) do
    if part_data.line_start and part_data.line_start >= from_line then
      part_data.line_start = part_data.line_start + delta
      part_data.line_end = part_data.line_end + delta
      shifted = true
      for _, action in ipairs(part_data.actions) do
        shift_action(action, delta)
      end
    end
  end

  if shifted then
    self._ranges_valid = false
    if self._max_line_end_valid then
      self._max_line_end = self._max_line_end + delta
    end
  end
end

return RenderState
