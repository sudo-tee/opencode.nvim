local entries = require('opencode.protocols.entries')
local Promise = require('opencode.promise')
local normalize = require('opencode.protocols.v2.normalize')
local boundary = require('opencode.protocols.v2.observation.boundary')

local M = {}

---@param kind 'text'|'reasoning'
---@param ordinal integer
---@return string
local function content_key(kind, ordinal)
  return kind .. ':' .. tostring(ordinal)
end

---@param observation OpencodeV2Observation
---@param entry table
local function rebuild_content_index(observation, entry)
  local index = {}
  local ordinals = { text = 0, reasoning = 0 }
  for _, content in ipairs(entry.content) do
    if ordinals[content.kind] then
      index[content_key(content.kind, ordinals[content.kind])] = content
      ordinals[content.kind] = ordinals[content.kind] + 1
    elseif content.kind == 'tool' and content.id then
      index['tool:' .. content.id] = content
    end
  end
  observation._v2_content_by_message[entry.id] = index
end

---@param observation OpencodeV2Observation
---@param entry table
---@return table
local function put_entry(observation, entry)
  local state = observation:read()
  local existing = state.entries_by_id[entry.id]
  state.entries_by_id[entry.id] = entries.replace(existing, entry)
  if not existing then
    state.entry_order[#state.entry_order + 1] = entry.id
  end
  rebuild_content_index(observation, state.entries_by_id[entry.id])
  return state.entries_by_id[entry.id]
end

---@param observation OpencodeV2Observation
---@param messages table[]
---@param merge? boolean
function M.ingest_snapshot(observation, messages, merge)
  local mapped, seen = {}, {}
  for index = #messages, 1, -1 do
    local entry = normalize.mapped_message(observation._session_id, messages[index])
    if entry then
      if seen[entry.id] then
        boundary.fail('snapshot contains a duplicate message')
      end
      seen[entry.id] = true
      mapped[#mapped + 1] = entry
    end
  end

  if merge then
    entries.prepend(observation:read(), mapped, function(entry)
      rebuild_content_index(observation, entry)
    end)
  else
    local state = observation:read()
    local entries_by_id, order = {}, {}
    for _, entry in ipairs(mapped) do
      entries_by_id[entry.id] = entries.replace(state.entries_by_id[entry.id], entry)
      order[#order + 1] = entry.id
    end
    state.entries_by_id, state.entry_order = entries_by_id, order
    observation._v2_content_by_message = {}
    for _, entry in ipairs(mapped) do
      rebuild_content_index(observation, entries_by_id[entry.id])
    end
  end
  observation:read().sync.messages = { state = 'current' }
end

---@param observation OpencodeV2Observation
---@param page OpencodeV2Page<table>
---@param older? boolean
function M.apply_page(observation, page, older)
  M.ingest_snapshot(observation, page.data, older)
  observation._v2_older_cursor = page.cursor.next
  observation._v2_history_complete = page.cursor.next == nil
end

---@param observation OpencodeV2Observation
---@param event_type string
---@param message string
---@return false
local function invalid(observation, event_type, message)
  return boundary.diagnostic(observation, 'messages', event_type .. ' ' .. message)
end

---@param observation OpencodeV2Observation
---@param data table
---@param event_type string
---@return table|nil
local function assistant_entry(observation, data, event_type)
  if type(data.assistantMessageID) ~= 'string' then
    invalid(observation, event_type, 'is missing assistantMessageID')
    return nil
  end
  local entry = observation:read().entries_by_id[data.assistantMessageID]
  if not entry or entry.kind ~= 'assistant' then
    invalid(observation, event_type, 'has no assistant message')
    return nil
  end
  return entry
end

---@param observation OpencodeV2Observation
---@param data table
---@param event_type string
---@param create boolean
---@return table|nil
local function ordinal_content(observation, data, event_type, create)
  local entry = assistant_entry(observation, data, event_type)
  if not entry then
    return nil
  end
  if type(data.ordinal) ~= 'number' or data.ordinal < 0 or data.ordinal % 1 ~= 0 then
    invalid(observation, event_type, 'has invalid ordinal')
    return nil
  end

  local kind = event_type:find('reasoning', 1, true) and 'reasoning' or 'text'
  local index = observation._v2_content_by_message[entry.id]
  local key = content_key(kind, data.ordinal)
  local content = index[key]
  if content or not create then
    return content
  end
  content = { kind = kind, text = '' }
  entry.content[#entry.content + 1] = content
  index[key] = content
  return content
end

---@param observation OpencodeV2Observation
---@param data table
---@param event_type string
---@param create boolean
---@return table|nil
local function tool_content(observation, data, event_type, create)
  local entry = assistant_entry(observation, data, event_type)
  if not entry then
    return nil
  end
  if type(data.id) ~= 'string' then
    invalid(observation, event_type, 'is missing tool id')
    return nil
  end

  local index = observation._v2_content_by_message[entry.id]
  local content = index['tool:' .. data.id]
  if content or not create then
    return content
  end
  if type(data.name) ~= 'string' then
    invalid(observation, event_type, 'is missing tool name')
    return nil
  end
  content = { id = data.id, kind = 'tool', call_id = data.id, name = data.name, state = 'streaming' }
  entry.content[#entry.content + 1] = content
  index['tool:' .. data.id] = content
  return content
end

---@type table<string, fun(observation: OpencodeV2Observation, event: OpencodeV2Event, data: table): boolean>
local handlers = {}

---@param observation OpencodeV2Observation
---@param event OpencodeV2Event
---@param data table
handlers['session.inbox.enqueued'] = function(observation, event, data)
  if type(data.inboxID) ~= 'string' or type(data.item) ~= 'table' or data.item.type ~= 'user' then
    return false
  end
  if type(data.item.payload) ~= 'table' then
    return invalid(observation, event.type, 'is missing user payload')
  end
  local info = vim.deepcopy(data.item.payload)
  info.id, info.type, info.time = data.inboxID, 'user', { created = event.created }
  local ok, entry = pcall(normalize.mapped_message, observation._session_id, info)
  if not ok then
    return boundary.diagnostic(observation, 'messages', tostring(entry))
  end
  ---@cast entry table
  put_entry(observation, entry)
  return true
end

---@param observation OpencodeV2Observation
---@param event OpencodeV2Event
---@param data table
handlers['session.step.started'] = function(observation, event, data)
  if type(data.assistantMessageID) ~= 'string' or type(data.agent) ~= 'string' then
    return invalid(observation, event.type, 'is missing assistant identity')
  end
  local existing = observation:read().entries_by_id[data.assistantMessageID]
  put_entry(observation, {
    id = data.assistantMessageID,
    session_id = observation._session_id,
    kind = 'assistant',
    agent = data.agent,
    model = normalize.mapped_model(data.model),
    snapshot = data.snapshot and { start = data.snapshot } or nil,
    time = { created = event.created },
    content = existing and existing.content or {},
  })
  return true
end

---@param observation OpencodeV2Observation
---@param event OpencodeV2Event
---@param data table
handlers['session.step.streamed'] = function(observation, event, data)
  local entry = assistant_entry(observation, data, event.type)
  if not entry then
    return false
  end
  entry.time = entry.time or {}
  entry.time.streamed = event.created
  return true
end

---@param observation OpencodeV2Observation
---@param event OpencodeV2Event
---@param data table
---@return boolean
local function finish_step(observation, event, data)
  local entry = assistant_entry(observation, data, event.type)
  if not entry then
    return false
  end
  entry.time = entry.time or {}
  entry.time.completed = event.created
  entry.finish = data.finish
  entry.cost = data.cost
  entry.tokens = normalize.mapped_tokens(data.tokens)
  entry.error = normalize.mapped_error(data.error)
  entry.snapshot = entry.snapshot or {}
  entry.snapshot['end'] = data.snapshot
  entry.snapshot.files = vim.deepcopy(data.files)
  return true
end
handlers['session.step.ended'] = finish_step
handlers['session.step.failed'] = finish_step

---@param observation OpencodeV2Observation
---@param event OpencodeV2Event
---@param data table
---@return boolean
local function start_text(observation, event, data)
  local content = ordinal_content(observation, data, event.type, true)
  if not content then
    return false
  end
  if content.kind == 'reasoning' then
    content.time = { created = event.created }
  end
  return true
end
handlers['session.text.started'] = start_text
handlers['session.reasoning.started'] = start_text

---@param field 'delta'|'text'
---@param append boolean
---@return fun(observation: OpencodeV2Observation, event: OpencodeV2Event, data: table): boolean
local function update_text(field, append)
  ---@param observation OpencodeV2Observation
  ---@param event OpencodeV2Event
  ---@param data table
  return function(observation, event, data)
    local content = ordinal_content(observation, data, event.type, false)
    if not content or type(data[field]) ~= 'string' then
      return invalid(observation, event.type, 'cannot identify started content')
    end
    content.text = append and (content.text .. data[field]) or data[field]
    if not append and content.kind == 'reasoning' then
      content.time = content.time or {}
      content.time.completed = event.created
    end
    return true
  end
end
handlers['session.text.delta'] = update_text('delta', true)
handlers['session.reasoning.delta'] = handlers['session.text.delta']
handlers['session.text.ended'] = update_text('text', false)
handlers['session.reasoning.ended'] = handlers['session.text.ended']

---@param observation OpencodeV2Observation
---@param event OpencodeV2Event
---@param data table
handlers['session.tool.input.started'] = function(observation, event, data)
  return tool_content(observation, data, event.type, true) ~= nil
end

---@param field 'delta'|'text'
---@param append boolean
---@return fun(observation: OpencodeV2Observation, event: OpencodeV2Event, data: table): boolean
local function tool_input(field, append)
  ---@param observation OpencodeV2Observation
  ---@param event OpencodeV2Event
  ---@param data table
  return function(observation, event, data)
    local content = tool_content(observation, data, event.type, false)
    if not content or content.state ~= 'streaming' or type(data[field]) ~= 'string' then
      return invalid(observation, event.type, 'cannot identify a streaming tool')
    end
    content.input_text = append and ((content.input_text or '') .. data[field]) or data[field]
    return true
  end
end
handlers['session.tool.input.delta'] = tool_input('delta', true)
handlers['session.tool.input.ended'] = tool_input('text', false)

---@param observation OpencodeV2Observation
---@param event OpencodeV2Event
---@param data table
handlers['session.tool.called'] = function(observation, event, data)
  local content = tool_content(observation, data, event.type, false)
  if not content or type(data.input) ~= 'table' then
    return invalid(observation, event.type, 'cannot identify a tool input')
  end
  content.state = 'running'
  content.input = vim.deepcopy(data.input)
  normalize.apply_tool_input(content, content.name, content.input)
  content.input_text = nil
  content.executed = data.executed
  content.time = content.time or { created = event.created }
  content.time.started = event.created
  return true
end

---@param observation OpencodeV2Observation
---@param event OpencodeV2Event
---@param data table
handlers['session.tool.progress'] = function(observation, event, data)
  local content = tool_content(observation, data, event.type, false)
  if not content or content.state ~= 'running' then
    return invalid(observation, event.type, 'cannot identify a running tool')
  end
  normalize.apply_tool_metadata(content, content.name, data.metadata)
  return true
end

---@param observation OpencodeV2Observation
---@param event OpencodeV2Event
---@param data table
---@return boolean
local function finish_tool(observation, event, data)
  local content = tool_content(observation, data, event.type, false)
  if not content or content.state == 'completed' or content.state == 'error' then
    return false
  end
  local succeeded = event.type == 'session.tool.success'
  if succeeded and type(data.content) ~= 'table' then
    return invalid(observation, event.type, 'is missing result content')
  end
  content.state = succeeded and 'completed' or 'error'
  content.executed = data.executed
  content.result = nil
  if data.content ~= nil then
    content.result = vim.tbl_map(normalize.mapped_tool_result, data.content)
  end
  content.error = normalize.mapped_error(data.error)
  normalize.apply_tool_metadata(content, content.name, data.metadata)
  content.time = content.time or { created = event.created }
  content.time.completed = event.created
  return true
end
handlers['session.tool.success'] = finish_tool
handlers['session.tool.failed'] = finish_tool

---@param observation OpencodeV2Observation
---@param event OpencodeV2Event
---@return boolean changed
function M.ingest_event(observation, event)
  local handler = handlers[event.type]
  if not handler or event.data.sessionID ~= observation._session_id then
    return false
  end
  if not handler(observation, event, event.data) then
    return false
  end
  observation:read().sync.messages = { state = 'current' }
  return true
end

---@param observation OpencodeV2Observation
---@param input_id string
---@return table|nil
function M.find_reply(observation, input_id)
  local input_found, reply = false, nil
  local state = observation:read()
  for _, id in ipairs(state.entry_order) do
    local entry = state.entries_by_id[id]
    if entry.kind == 'user' then
      if input_found or entry.id ~= input_id then
        return nil
      end
      input_found = true
    elseif entry.kind == 'assistant' then
      if not input_found then
        return nil
      end
      reply = entry
    end
  end
  return input_found and reply or nil
end

---@param observation OpencodeV2Observation
function M.initialize(observation)
  observation._v2_content_by_message = {}
  observation._v2_older_cursor = nil
  observation._v2_history_complete = false
  observation._v2_older_loading = false
end

---@param observation OpencodeV2Observation
---@param connection OpencodeV2Connection
function M.attach_history(observation, connection)
  ---@return Promise
  function observation:load_older()
    if self._v2_older_loading then
      boundary.fail('load_older is already in progress')
    end
    if self._v2_history_complete or not self._v2_older_cursor then
      return Promise.new():resolve(nil)
    end

    self._v2_older_loading = true
    local finish = self:_begin_local_operation()
    local cursor = self._v2_older_cursor
    local revision = self._event_revisions.messages
    local ok, operation_request =
      pcall(connection.operations.list_messages, connection, self._session_id, cursor, 50, nil)
    if not ok then
      self._v2_older_loading = false
      finish()
      error(operation_request, 0)
    end
    local request = operation_request:and_then(function(page)
      ---@cast page OpencodeV2Page<table>
      if not self:_is_current() then
        boundary.fail('older messages arrived after Observation release')
      end
      if self._event_revisions.messages ~= revision then
        self:read().sync.messages = { state = 'stale' }
        self:_start_resource('messages')
        return
      end
      M.apply_page(self, page, true)
      self:_notify('messages')
    end)
    return request:finally(function()
      self._v2_older_loading = false
      finish()
    end)
  end

  ---@return Promise
  function observation:load_complete_history()
    ---@return Promise
    local function pull()
      if self._v2_history_complete or not self._v2_older_cursor then
        return Promise.new():resolve(nil)
      end
      return self:load_older():and_then(pull)
    end
    return pull()
  end
end

---@param observation OpencodeV2Observation
function M.release(observation)
  observation._v2_content_by_message = {}
  observation._v2_older_cursor = nil
  observation._v2_history_complete = false
end

return M
