local lifecycle = require('opencode.protocols.observation')
local Promise = require('opencode.promise')
local util = require('opencode.util')

local M = {}

local function fail(message)
  error('V2 observation: ' .. message, 0)
end

local function record_diagnostic(observation, resource, message)
  observation:read().sync[resource] = lifecycle.sync_error('protocol_contract', message)
end

local function mapped_error(value)
  if type(value) ~= 'table' then
    if value == nil then
      return nil
    end
    return { message = tostring(value) }
  end
  local result = {}
  result.type = value.name or value.type or value.tag
  result.message = value.message
  result.status = value.status or value.statusCode
  if value.retryable ~= nil then
    result.retryable = value.retryable
  else
    result.retryable = value.isRetryable
  end
  result.provider_id = value.providerID
  result.ref = value.ref
  result.retries = value.retries
  if not next(result) then
    result.type = 'unknown'
  end
  return result
end

local function mapped_time(value)
  if value == nil then
    return nil
  end
  if type(value) ~= 'table' then
    fail('invalid message time')
  end
  local result = {}
  for _, key in ipairs({ 'created', 'streamed', 'completed' }) do
    if value[key] ~= nil then
      if type(value[key]) ~= 'number' then
        fail('invalid message time.' .. key)
      end
      result[key] = value[key]
    end
  end
  return result
end

local function mapped_tokens(value)
  if value == nil then
    return nil
  end
  if type(value) ~= 'table' then
    fail('invalid token usage')
  end
  local result = {}
  for _, key in ipairs({ 'input', 'output', 'reasoning' }) do
    if value[key] ~= nil then
      if type(value[key]) ~= 'number' then
        fail('invalid token usage.' .. key)
      end
      result[key] = value[key]
    end
  end
  if value.cache ~= nil then
    if type(value.cache) ~= 'table' then
      fail('invalid token usage.cache')
    end
    result.cache = {}
    for _, key in ipairs({ 'read', 'write' }) do
      if value.cache[key] ~= nil then
        if type(value.cache[key]) ~= 'number' then
          fail('invalid token usage.cache.' .. key)
        end
        result.cache[key] = value.cache[key]
      end
    end
  end
  return result
end

local function mapped_model(value)
  if value == nil then
    return nil
  end
  if type(value) ~= 'table' or type(value.providerID) ~= 'string' or type(value.id) ~= 'string' then
    fail('invalid model reference')
  end
  return { providerID = value.providerID, modelID = value.id, variant = value.variant }
end

local function mapped_mention(value, text)
  if value == nil then
    return nil
  end
  if
    type(value) ~= 'table'
    or type(value.start) ~= 'number'
    or type(value['end']) ~= 'number'
    or value.start % 1 ~= 0
    or value['end'] % 1 ~= 0
    or value.start < 0
    or value['end'] < value.start
    or type(value.text) ~= 'string'
  then
    fail('invalid prompt mention')
  end
  if not util.is_utf16_boundary(text, value.start) or not util.is_utf16_boundary(text, value['end']) then
    fail('prompt mention does not identify a UTF-16 text range')
  end
  local start_byte = util.byte_index_from_utf16(text, value.start)
  local end_byte = util.byte_index_from_utf16(text, value['end'])
  if not start_byte or not end_byte or text:sub(start_byte + 1, end_byte) ~= value.text then
    fail('prompt mention does not identify a UTF-16 text range')
  end
  return { text = value.text, start_byte = start_byte, end_byte = end_byte }
end

local function mapped_file(file, prompt_text)
  if type(file) ~= 'table' or type(file.mime) ~= 'string' or type(file.data) ~= 'string' then
    fail('invalid file attachment')
  end
  local result = {
    kind = 'file',
    uri = 'data:' .. file.mime .. ';base64,' .. file.data,
    media_type = file.mime,
    name = file.name,
    mention = mapped_mention(file.mention, prompt_text),
  }
  if type(file.source) == 'table' and file.source.type == 'uri' and type(file.source.uri) == 'string' then
    result.source = { kind = 'resource', uri = file.source.uri }
  elseif type(file.source) ~= 'table' or file.source.type ~= 'inline' then
    fail('invalid file attachment source')
  end
  return result
end

local function mapped_tool_result(value)
  if type(value) ~= 'table' then
    fail('invalid tool result')
  end
  if value.type == 'text' and type(value.text) == 'string' then
    return { kind = 'text', text = value.text }
  elseif value.type == 'file' and type(value.uri) == 'string' and type(value.mime) == 'string' then
    return { kind = 'file', uri = value.uri, media_type = value.mime, name = value.name }
  end
  fail('invalid tool result content')
end

local function mapped_tool(part)
  if
    type(part.id) ~= 'string'
    or type(part.name) ~= 'string'
    or type(part.state) ~= 'table'
    or type(part.time) ~= 'table'
    or type(part.time.created) ~= 'number'
  then
    fail('invalid assistant tool content')
  end
  local status = part.state.status
  if status ~= 'streaming' and status ~= 'running' and status ~= 'completed' and status ~= 'error' then
    fail('invalid assistant tool state')
  end
  local result = {
    id = part.id,
    kind = 'tool',
    call_id = part.id,
    name = part.name,
    state = status,
    executed = part.executed,
    time = {
      created = part.time.created,
      started = part.time.ran,
      completed = part.time.completed,
    },
  }
  if status == 'streaming' then
    if type(part.state.input) ~= 'string' then
      fail('invalid streaming tool input')
    end
    result.input_text = part.state.input
  else
    if type(part.state.input) ~= 'table' then
      fail('invalid tool input')
    end
    result.input = vim.deepcopy(part.state.input)
  end
  if status == 'completed' or status == 'error' then
    if status == 'completed' and type(part.state.content) ~= 'table' then
      fail('completed tool is missing result content')
    end
    if part.state.content ~= nil then
      result.result = {}
      for _, item in ipairs(part.state.content) do
        result.result[#result.result + 1] = mapped_tool_result(item)
      end
    end
    result.error = mapped_error(part.state.error)
  end
  return result
end

local function mapped_assistant_content(part)
  if type(part) ~= 'table' then
    fail('invalid assistant content')
  end
  if part.type == 'text' then
    if type(part.text) ~= 'string' then
      fail('invalid assistant text content')
    end
    return { kind = 'text', text = part.text }
  elseif part.type == 'reasoning' then
    if type(part.text) ~= 'string' then
      fail('invalid assistant reasoning content')
    end
    return {
      kind = 'reasoning',
      text = part.text,
      time = part.time and { created = part.time.created, completed = part.time.completed } or nil,
    }
  elseif part.type == 'tool' then
    return mapped_tool(part)
  end
  fail('unknown assistant content type: ' .. tostring(part.type))
end

local function base_entry(observation, info)
  if type(info) ~= 'table' or type(info.id) ~= 'string' or type(info.type) ~= 'string' then
    fail('invalid message info')
  end
  return {
    id = info.id,
    session_id = observation._session_id,
    kind = info.type,
    time = mapped_time(info.time),
    content = {},
  }
end

local function mapped_message(observation, info)
  local entry = base_entry(observation, info)
  if info.type == 'idle' then
    if info.outcome ~= 'succeeded' and info.outcome ~= 'failed' and info.outcome ~= 'interrupted' then
      fail('invalid idle message')
    end
    return nil
  elseif info.type == 'user' then
    if type(info.text) ~= 'string' then
      fail('invalid user message')
    end
    entry.content[#entry.content + 1] = { kind = 'text', text = info.text }
    for _, file in ipairs(info.files or {}) do
      entry.content[#entry.content + 1] = mapped_file(file, info.text)
    end
    for _, agent in ipairs(info.agents or {}) do
      if type(agent) ~= 'table' or type(agent.name) ~= 'string' then
        fail('invalid agent attachment')
      end
      entry.content[#entry.content + 1] = {
        kind = 'agent',
        name = agent.name,
        mention = mapped_mention(agent.mention, info.text),
      }
    end
    for _, skill in ipairs(info.skills or {}) do
      if type(skill) ~= 'table' or type(skill.id) ~= 'string' or type(skill.name) ~= 'string' then
        fail('invalid skill attachment')
      end
      entry.content[#entry.content + 1] = {
        kind = 'skill',
        skill_id = skill.id,
        name = skill.name,
        text = skill.text,
        mention = mapped_mention(skill.mention, info.text),
      }
    end
  elseif info.type == 'assistant' then
    if type(info.agent) ~= 'string' or type(info.content) ~= 'table' then
      fail('invalid assistant message')
    end
    entry.agent = info.agent
    entry.model = mapped_model(info.model)
    entry.snapshot = vim.deepcopy(info.snapshot)
    entry.finish = info.finish
    entry.cost = info.cost
    entry.tokens = mapped_tokens(info.tokens)
    entry.error = mapped_error(info.error)
    if info.retry ~= nil then
      if type(info.retry) ~= 'table' or type(info.retry.attempt) ~= 'number' or type(info.retry.at) ~= 'number' then
        fail('invalid assistant retry')
      end
      entry.retry = {
        attempt = info.retry.attempt,
        scheduled_at = info.retry.at,
        error = mapped_error(info.retry.error),
      }
    end
    for _, part in ipairs(info.content) do
      entry.content[#entry.content + 1] = mapped_assistant_content(part)
    end
  elseif info.type == 'synthetic' or info.type == 'system' then
    if type(info.text) ~= 'string' then
      fail('invalid ' .. info.type .. ' message')
    end
    entry.description = info.description
    entry.content[1] = { kind = 'text', text = info.text }
  elseif info.type == 'skill' then
    if type(info.skill) ~= 'string' or type(info.name) ~= 'string' or type(info.text) ~= 'string' then
      fail('invalid skill message')
    end
    entry.skill_id = info.skill
    entry.name = info.name
    entry.content[1] = { kind = 'text', text = info.text }
  elseif info.type == 'shell' then
    if type(info.shellID) ~= 'string' or type(info.command) ~= 'string' or type(info.status) ~= 'string' then
      fail('invalid shell message')
    end
    entry.shell_id = info.shellID
    entry.command = info.command
    entry.state = info.status
    entry.exit = info.exit
    if info.output ~= nil then
      entry.content[1] =
        { kind = 'text', text = type(info.output) == 'string' and info.output or vim.inspect(info.output) }
    end
  elseif info.type == 'compaction' then
    if type(info.status) ~= 'string' or type(info.reason) ~= 'string' then
      fail('invalid compaction message')
    end
    entry.state = info.status
    entry.reason = info.reason
    entry.summary = info.summary
    entry.recent = info.recent
    entry.model = mapped_model(info.model)
    entry.error = mapped_error(info.error)
    entry.cost = info.cost
    entry.tokens = mapped_tokens(info.tokens)
  elseif info.type == 'agent-switched' then
    if type(info.agent) ~= 'string' then
      fail('invalid agent-switched message')
    end
    entry.agent = info.agent
    entry.previous = info.previous
  elseif info.type == 'model-switched' then
    entry.model = mapped_model(info.model)
    entry.previous = mapped_model(info.previous)
  elseif info.type == 'location-switched' then
    if type(info.location) ~= 'table' then
      fail('invalid location-switched message')
    end
    entry.location = vim.deepcopy(info.location)
    entry.project_id = info.projectID
    entry.subpath = info.subpath
    if info.previous ~= nil then
      entry.previous = {
        location = vim.deepcopy(info.previous.location),
        project_id = info.previous.projectID,
        subpath = info.previous.subpath,
      }
    end
  else
    fail('unknown message type: ' .. info.type)
  end
  return entry
end

local function replace_entry(existing, replacement)
  if not existing then
    return replacement
  end
  for key in pairs(existing) do
    existing[key] = nil
  end
  for key, value in pairs(replacement) do
    existing[key] = value
  end
  return existing
end

local function content_key(kind, ordinal)
  return kind .. ':' .. tostring(ordinal)
end

local function rebuild_content_index(observation, entry)
  local index = {}
  local ordinals = { text = 0, reasoning = 0 }
  for _, content in ipairs(entry.content) do
    if content.kind == 'text' or content.kind == 'reasoning' then
      index[content_key(content.kind, ordinals[content.kind])] = content
      ordinals[content.kind] = ordinals[content.kind] + 1
    elseif content.kind == 'tool' and content.id then
      index['tool:' .. content.id] = content
    end
  end
  observation._v2_content_by_message[entry.id] = index
end

local function put_entry(observation, entry)
  local state = observation:read()
  local existing = state.entries_by_id[entry.id]
  state.entries_by_id[entry.id] = replace_entry(existing, entry)
  if not existing then
    state.entry_order[#state.entry_order + 1] = entry.id
  end
  rebuild_content_index(observation, state.entries_by_id[entry.id])
  return state.entries_by_id[entry.id]
end

---@param observation table
---@param messages table[]
---@param merge? boolean
function M.ingest_snapshot(observation, messages, merge)
  if type(messages) ~= 'table' then
    fail('snapshot must be a message list')
  end
  local mapped, seen = {}, {}
  for index = #messages, 1, -1 do
    local entry = mapped_message(observation, messages[index])
    if entry then
      if seen[entry.id] then
        fail('snapshot contains a duplicate message')
      end
      seen[entry.id] = true
      mapped[#mapped + 1] = entry
    end
  end
  if not merge then
    local state = observation:read()
    local entries, order = {}, {}
    for _, entry in ipairs(mapped) do
      entries[entry.id] = replace_entry(state.entries_by_id[entry.id], entry)
      order[#order + 1] = entry.id
    end
    state.entries_by_id = entries
    state.entry_order = order
    observation._v2_content_by_message = {}
    for _, entry in ipairs(mapped) do
      rebuild_content_index(observation, entries[entry.id])
    end
  else
    local prefix = {}
    for _, entry in ipairs(mapped) do
      if not observation:read().entries_by_id[entry.id] then
        observation:read().entries_by_id[entry.id] = entry
        rebuild_content_index(observation, entry)
        prefix[#prefix + 1] = entry.id
      end
    end
    if #prefix > 0 then
      vim.list_extend(prefix, observation:read().entry_order)
      observation:read().entry_order = prefix
    end
  end
  observation:read().sync.messages = { state = 'current' }
end

local function event_identity(observation, event, resource)
  if type(event) ~= 'table' or type(event.type) ~= 'string' or type(event.data) ~= 'table' then
    record_diagnostic(observation, resource, 'invalid V2 event envelope')
    return nil
  end
  if type(event.data.sessionID) ~= 'string' then
    record_diagnostic(observation, resource, event.type .. ' is missing sessionID')
    return nil
  end
  if event.data.sessionID ~= observation._session_id then
    return false
  end
  return event.data
end

local function assistant_entry(observation, data, event_type)
  if type(data.assistantMessageID) ~= 'string' then
    record_diagnostic(observation, 'messages', event_type .. ' is missing assistantMessageID')
    return nil
  end
  local entry = observation:read().entries_by_id[data.assistantMessageID]
  if not entry or entry.kind ~= 'assistant' then
    record_diagnostic(observation, 'messages', event_type .. ' has no assistant message')
    return nil
  end
  return entry
end

local function ordinal_content(observation, data, event_type, kind, create)
  local entry = assistant_entry(observation, data, event_type)
  if not entry then
    return nil
  end
  if type(data.ordinal) ~= 'number' or data.ordinal < 0 or data.ordinal % 1 ~= 0 then
    record_diagnostic(observation, 'messages', event_type .. ' has invalid ordinal')
    return nil
  end
  local index = observation._v2_content_by_message[entry.id]
  local key = content_key(kind, data.ordinal)
  local content = index and index[key] or nil
  if content or not create then
    return content, entry
  end
  content = { kind = kind, text = '' }
  entry.content[#entry.content + 1] = content
  index[key] = content
  return content, entry
end

local function tool_content(observation, data, event_type, create)
  local entry = assistant_entry(observation, data, event_type)
  if not entry then
    return nil
  end
  if type(data.id) ~= 'string' then
    record_diagnostic(observation, 'messages', event_type .. ' is missing tool id')
    return nil
  end
  local index = observation._v2_content_by_message[entry.id]
  local content = index and index['tool:' .. data.id] or nil
  if content or not create then
    return content, entry
  end
  if type(data.name) ~= 'string' then
    record_diagnostic(observation, 'messages', event_type .. ' is missing tool name')
    return nil
  end
  content = { id = data.id, kind = 'tool', call_id = data.id, name = data.name, state = 'streaming' }
  entry.content[#entry.content + 1] = content
  index['tool:' .. data.id] = content
  return content, entry
end

---@param observation table
---@param event table
---@return boolean changed
function M.ingest_event(observation, event)
  local data = event_identity(observation, event, 'messages')
  if data == nil or data == false then
    return false
  end
  local kind = event.type
  if kind == 'session.inbox.enqueued' then
    if type(data.inboxID) ~= 'string' or type(data.item) ~= 'table' or data.item.type ~= 'user' then
      return false
    end
    if type(data.item.payload) ~= 'table' then
      record_diagnostic(observation, 'messages', kind .. ' is missing user payload')
      return false
    end
    local info = vim.deepcopy(data.item.payload)
    info.id = data.inboxID
    info.type = 'user'
    info.time = { created = event.created }
    local ok, entry = pcall(mapped_message, observation, info)
    if not ok then
      record_diagnostic(observation, 'messages', tostring(entry))
      return false
    end
    put_entry(observation, entry)
  elseif kind == 'session.step.started' then
    if type(data.assistantMessageID) ~= 'string' or type(data.agent) ~= 'string' then
      record_diagnostic(observation, 'messages', kind .. ' is missing assistant identity')
      return false
    end
    local state = observation:read()
    local existing = state.entries_by_id[data.assistantMessageID]
    local entry = {
      id = data.assistantMessageID,
      session_id = observation._session_id,
      kind = 'assistant',
      agent = data.agent,
      model = mapped_model(data.model),
      snapshot = data.snapshot and { start = data.snapshot } or nil,
      time = { created = event.created },
      content = existing and existing.content or {},
    }
    put_entry(observation, entry)
  elseif kind == 'session.step.streamed' then
    local entry = assistant_entry(observation, data, kind)
    if not entry then
      return false
    end
    entry.time = entry.time or {}
    entry.time.streamed = event.created
  elseif kind == 'session.step.ended' or kind == 'session.step.failed' then
    local entry = assistant_entry(observation, data, kind)
    if not entry then
      return false
    end
    entry.time = entry.time or {}
    entry.time.completed = event.created
    entry.finish = data.finish
    entry.cost = data.cost
    entry.tokens = mapped_tokens(data.tokens)
    entry.error = mapped_error(data.error)
    entry.snapshot = entry.snapshot or {}
    entry.snapshot['end'] = data.snapshot
    entry.snapshot.files = vim.deepcopy(data.files)
  elseif kind == 'session.text.started' or kind == 'session.reasoning.started' then
    local content = ordinal_content(observation, data, kind, kind:match('text') and 'text' or 'reasoning', true)
    if not content then
      return false
    end
    if kind == 'session.reasoning.started' then
      content.time = { created = event.created }
    end
  elseif kind == 'session.text.delta' or kind == 'session.reasoning.delta' then
    local content = ordinal_content(observation, data, kind, kind:match('text') and 'text' or 'reasoning', false)
    if not content or type(data.delta) ~= 'string' then
      record_diagnostic(observation, 'messages', kind .. ' cannot identify started content')
      return false
    end
    content.text = content.text .. data.delta
  elseif kind == 'session.text.ended' or kind == 'session.reasoning.ended' then
    local content = ordinal_content(observation, data, kind, kind:match('text') and 'text' or 'reasoning', false)
    if not content or type(data.text) ~= 'string' then
      record_diagnostic(observation, 'messages', kind .. ' cannot identify started content')
      return false
    end
    content.text = data.text
    if content.kind == 'reasoning' then
      content.time = content.time or {}
      content.time.completed = event.created
    end
  elseif kind == 'session.tool.input.started' then
    if not tool_content(observation, data, kind, true) then
      return false
    end
  elseif kind == 'session.tool.input.delta' then
    local content = tool_content(observation, data, kind, false)
    if not content or content.state ~= 'streaming' or type(data.delta) ~= 'string' then
      record_diagnostic(observation, 'messages', kind .. ' cannot identify a streaming tool')
      return false
    end
    content.input_text = (content.input_text or '') .. data.delta
  elseif kind == 'session.tool.input.ended' then
    local content = tool_content(observation, data, kind, false)
    if not content or content.state ~= 'streaming' or type(data.text) ~= 'string' then
      record_diagnostic(observation, 'messages', kind .. ' cannot identify a streaming tool')
      return false
    end
    content.input_text = data.text
  elseif kind == 'session.tool.called' then
    local content = tool_content(observation, data, kind, false)
    if not content or type(data.input) ~= 'table' then
      record_diagnostic(observation, 'messages', kind .. ' cannot identify a tool input')
      return false
    end
    content.state = 'running'
    content.input = vim.deepcopy(data.input)
    content.input_text = nil
    content.executed = data.executed
    content.time = content.time or { created = event.created }
    content.time.started = event.created
  elseif kind == 'session.tool.progress' then
    local content = tool_content(observation, data, kind, false)
    if not content or content.state ~= 'running' then
      record_diagnostic(observation, 'messages', kind .. ' cannot identify a running tool')
      return false
    end
  elseif kind == 'session.tool.success' or kind == 'session.tool.failed' then
    local content = tool_content(observation, data, kind, false)
    if not content then
      return false
    end
    if content.state == 'completed' or content.state == 'error' then
      return false
    end
    if type(data.content) ~= 'table' and kind == 'session.tool.success' then
      record_diagnostic(observation, 'messages', kind .. ' is missing result content')
      return false
    end
    content.state = kind == 'session.tool.success' and 'completed' or 'error'
    content.executed = data.executed
    content.result = nil
    if data.content ~= nil then
      content.result = {}
      for _, item in ipairs(data.content) do
        content.result[#content.result + 1] = mapped_tool_result(item)
      end
    end
    content.error = mapped_error(data.error)
    content.time = content.time or { created = event.created }
    content.time.completed = event.created
  else
    return false
  end
  observation:read().sync.messages = { state = 'current' }
  return true
end

local function release_admission(observation, admission)
  local release = admission.release
  if not release then
    return
  end
  admission.release = nil
  release()
end

local function mark_admissions_unknown(observation, reason)
  local message = 'V2 observation: admission_unknown: ' .. tostring(reason)
  local consumed = {}
  for id, admission in pairs(observation._v2_admissions) do
    if not admission.terminal and not admission.unknown then
      admission.unknown = { kind = 'admission_unknown', message = message }
    end
    if admission.unknown and #admission.waiters > 0 then
      for _, waiter in ipairs(admission.waiters) do
        waiter:reject(admission.unknown.message)
      end
      admission.waiters = {}
      consumed[#consumed + 1] = id
    end
    if admission.unknown then
      release_admission(observation, admission)
    end
  end
  for _, id in ipairs(consumed) do
    observation._v2_admissions[id] = nil
  end
end

local function remove_from_order(order, id)
  for index, value in ipairs(order) do
    if value == id then
      table.remove(order, index)
      return
    end
  end
end

local function session_fact(info)
  if
    type(info) ~= 'table'
    or type(info.id) ~= 'string'
    or type(info.projectID) ~= 'string'
    or type(info.location) ~= 'table'
    or type(info.location.directory) ~= 'string'
    or type(info.time) ~= 'table'
    or type(info.time.created) ~= 'number'
    or type(info.time.updated) ~= 'number'
  then
    fail('invalid session info')
  end
  local time = {
    created = info.time.created,
    updated = info.time.updated,
    idle = info.time.idle,
    viewed = info.time.viewed,
    archived = info.time.archived,
  }
  return {
    id = info.id,
    parentID = info.parentID,
    projectID = info.projectID,
    agent = info.agent,
    model = mapped_model(info.model),
    cost = info.cost,
    tokens = mapped_tokens(info.tokens),
    outcome = info.outcome,
    time = time,
    title = info.title,
    location = vim.deepcopy(info.location),
    subpath = info.subpath,
    metadata = vim.deepcopy(info.metadata),
    permissions = vim.deepcopy(info.permissions),
    revert = vim.deepcopy(info.revert),
  }
end

local function inbox_fact(item, status)
  if
    type(item) ~= 'table'
    or type(item.id) ~= 'string'
    or type(item.sessionID) ~= 'string'
    or type(item.type) ~= 'string'
    or type(item.timeCreated) ~= 'number'
  then
    fail('invalid inbox item')
  end
  if item.delivery ~= 'steer' and item.delivery ~= 'queue' then
    fail('invalid inbox delivery')
  end
  return {
    id = item.id,
    session_id = item.sessionID,
    kind = item.type,
    delivery = item.delivery,
    status = status or 'pending',
    created_at_ms = item.timeCreated,
  }
end

local function permission_fact(request)
  if
    type(request) ~= 'table'
    or type(request.id) ~= 'string'
    or type(request.sessionID) ~= 'string'
    or type(request.action) ~= 'string'
    or type(request.resources) ~= 'table'
  then
    fail('invalid permission request')
  end
  return {
    id = request.id,
    session_id = request.sessionID,
    action = request.action,
    resources = vim.deepcopy(request.resources),
    choices = {
      { value = 'once', label = 'Allow once', description = 'Allow this request once' },
      { value = 'always', label = 'Always allow', description = 'Save an allow rule' },
      { value = 'reject', label = 'Reject', description = 'Reject this request' },
    },
    status = 'pending',
    message = request.message,
    source = vim.deepcopy(request.source),
  }
end

local function question_fact(form)
  if
    type(form) ~= 'table'
    or type(form.id) ~= 'string'
    or type(form.sessionID) ~= 'string'
    or type(form.fields) ~= 'table'
  then
    fail('invalid form request')
  end
  local fields, unavailable = {}, nil
  for _, field in ipairs(form.fields) do
    if type(field) ~= 'table' or type(field.key) ~= 'string' or type(field.type) ~= 'string' then
      fail('invalid form field')
    end
    if field.when ~= nil or field.type == 'external' then
      unavailable = 'conditional and external fields require the native client'
    end
    fields[#fields + 1] = {
      key = field.key,
      prompt = field.description,
      title = field.title,
      type = field.type,
      required = field.required,
      options = vim.deepcopy(field.options),
      custom = field.custom,
      minimum = field.minimum,
      maximum = field.maximum,
      min_items = field.minItems,
      max_items = field.maxItems,
    }
  end
  return {
    id = form.id,
    session_id = form.sessionID,
    title = form.title,
    fields = fields,
    status = 'pending',
    unavailable_reason = unavailable,
  }
end

local function put_child(children, child)
  local existed = children.by_id[child.id] ~= nil
  children.by_id[child.id] = child
  if not existed then
    children.order[#children.order + 1] = child.id
  end
end

local function apply_inbox_snapshot(observation, items)
  if type(items) ~= 'table' then
    fail('inbox snapshot must be a list')
  end
  local state = observation:read()
  local result = { items_by_id = {}, order = {} }
  for _, item in ipairs(items) do
    local terminal = observation._v2_inbox_terminal[item.id]
    local mapped = inbox_fact(item, terminal and terminal.status)
    if mapped.session_id ~= state.session.id then
      fail('inbox snapshot contains another session')
    end
    result.items_by_id[mapped.id] = mapped
    result.order[#result.order + 1] = mapped.id
  end
  for id, terminal in pairs(observation._v2_inbox_terminal) do
    if not result.items_by_id[id] then
      result.items_by_id[id] = vim.deepcopy(terminal)
      result.order[#result.order + 1] = id
    end
  end
  for id, existing in pairs(state.inbox.items_by_id) do
    if not result.items_by_id[id] then
      local missing = vim.deepcopy(existing)
      missing.status = 'not_pending'
      result.items_by_id[id] = missing
      result.order[#result.order + 1] = id
    end
  end
  state.inbox = result
end

local function apply_resource(observation, resource, value)
  local state = observation:read()
  if resource == 'session' then
    local session = session_fact(value)
    if session.id ~= state.session.id then
      fail('session snapshot belongs to another session')
    end
    state.session = session
  elseif resource == 'children' then
    local children = { by_id = {}, order = {} }
    for _, info in ipairs(value) do
      local child = session_fact(info)
      if child.parentID ~= state.session.id then
        fail('children snapshot contains another parent')
      end
      put_child(children, child)
    end
    state.children = children
  elseif resource == 'messages' then
    if type(value) ~= 'table' or type(value.data) ~= 'table' or type(value.cursor) ~= 'table' then
      fail('invalid message page')
    end
    M.ingest_snapshot(observation, value.data)
    observation._v2_older_cursor = value.cursor.next
    observation._v2_history_complete = value.cursor.next == nil
  elseif resource == 'inbox' then
    apply_inbox_snapshot(observation, value)
  elseif resource == 'execution' then
    if type(value) ~= 'table' then
      fail('invalid active session snapshot')
    end
    if value[state.session.id] then
      if type(value[state.session.id]) ~= 'table' or value[state.session.id].type ~= 'running' then
        fail('invalid active session state')
      end
      state.execution.activity = 'running'
    else
      state.execution.activity = 'idle'
      state.execution.last_outcome = state.session.outcome
      state.execution.last_idle = state.session.time and state.session.time.idle or nil
    end
  elseif resource == 'permissions' then
    local requests = {}
    for _, value_request in ipairs(value) do
      local request = permission_fact(value_request)
      if request.session_id == state.session.id then
        local terminal = observation._v2_permission_terminal[request.id]
        if terminal then
          request.status = 'answered'
          request.answer = terminal.answer
        end
        requests[request.id] = request
      end
    end
    state.permission_requests_by_id = requests
  elseif resource == 'questions' then
    local requests = {}
    for _, value_form in ipairs(value) do
      local form = question_fact(value_form)
      if form.session_id == state.session.id then
        local terminal = observation._v2_question_terminal[form.id]
        if terminal then
          form.status = terminal.status
          form.answers = vim.deepcopy(terminal.answers)
        end
        requests[form.id] = form
      end
    end
    state.question_requests_by_id = requests
  else
    fail('unsupported resource read: ' .. tostring(resource))
  end
end

local function terminal_inbox(observation, id, status, created)
  local state = observation:read()
  local item = state.inbox.items_by_id[id]
  if item then
    item.status = status
  else
    item = {
      id = id,
      session_id = observation._session_id,
      kind = 'unknown',
      status = status,
      created_at_ms = created,
    }
    state.inbox.items_by_id[id] = item
    state.inbox.order[#state.inbox.order + 1] = id
  end
  observation._v2_inbox_terminal[id] = vim.deepcopy(item)
end

local function settle_waiters(observation, terminal)
  local consumed = {}
  for id, admission in pairs(observation._v2_admissions) do
    if
      admission.delivered_serial
      and not admission.terminal
      and not admission.unknown
      and terminal.serial > admission.delivered_serial
    then
      admission.terminal = terminal
      for _, waiter in ipairs(admission.waiters) do
        waiter:resolve({
          kind = 'session_idle',
          outcome = terminal.outcome,
          idle_at = terminal.idle_at,
          error = terminal.error,
        })
      end
      if #admission.waiters > 0 then
        consumed[#consumed + 1] = id
      end
      admission.waiters = {}
      release_admission(observation, admission)
    end
  end
  for _, id in ipairs(consumed) do
    observation._v2_admissions[id] = nil
  end
end

local function execution_event(observation, event)
  local data = event_identity(observation, event, 'execution')
  if data == nil or data == false then
    return false
  end
  local state = observation:read()
  observation._v2_event_serial = observation._v2_event_serial + 1
  local serial = observation._v2_event_serial
  if event.type == 'session.execution.started' then
    if observation._v2_execution_event_active then
      state.execution = {
        activity = 'unknown',
        error = { kind = 'ambiguous_execution', message = 'overlapping V2 execution horizons' },
      }
      observation._v2_horizon_ambiguous = true
      mark_admissions_unknown(observation, 'overlapping execution horizons')
    else
      state.execution = { activity = 'running' }
      observation._v2_execution_event_active = true
      observation._v2_terminal_seen_since_start = false
    end
  elseif
    event.type == 'session.execution.succeeded'
    or event.type == 'session.execution.failed'
    or event.type == 'session.execution.interrupted'
  then
    if observation._v2_terminal_seen_since_start then
      return false
    end
    observation._v2_terminal_seen_since_start = true
    observation._v2_execution_event_active = false
    local outcome = event.type:match('%.([^.]+)$')
    local terminal = {
      serial = serial,
      outcome = outcome,
      idle_at = event.created,
      error = event.type == 'session.execution.failed' and mapped_error(data.error) or nil,
    }
    state.execution = { activity = 'idle', last_outcome = outcome, last_idle = event.created }
    observation._v2_last_terminal = terminal
    settle_waiters(observation, terminal)
  else
    return false
  end
  state.sync.execution = { state = 'current' }
  return true
end

local function inbox_event(observation, event)
  if
    event.type ~= 'session.inbox.enqueued'
    and event.type ~= 'session.inbox.delivered'
    and event.type ~= 'session.inbox.cancelled'
    and event.type ~= 'session.inbox.delivery.changed'
  then
    return false
  end
  local data = event_identity(observation, event, 'inbox')
  if data == nil or data == false then
    return false
  end
  local state = observation:read()
  observation._v2_event_serial = observation._v2_event_serial + 1
  local serial = observation._v2_event_serial
  if type(data.inboxID) ~= 'string' then
    record_diagnostic(observation, 'inbox', event.type .. ' is missing inboxID')
    return false
  end
  if event.type == 'session.inbox.enqueued' then
    if type(data.item) ~= 'table' then
      record_diagnostic(observation, 'inbox', 'session.inbox.enqueued is missing item')
      return false
    end
    local native = vim.deepcopy(data.item)
    native.id = data.inboxID
    native.sessionID = observation._session_id
    native.timeCreated = event.created
    local item = inbox_fact(native)
    local terminal = observation._v2_inbox_terminal[item.id]
    if terminal then
      item.status = terminal.status
    end
    if not state.inbox.items_by_id[item.id] then
      state.inbox.order[#state.inbox.order + 1] = item.id
    end
    state.inbox.items_by_id[item.id] = item
  elseif event.type == 'session.inbox.delivered' or event.type == 'session.inbox.cancelled' then
    local status = event.type == 'session.inbox.delivered' and 'delivered' or 'cancelled'
    terminal_inbox(observation, data.inboxID, status, event.created)
    if status == 'delivered' then
      observation._v2_delivered[data.inboxID] = serial
      local admission = observation._v2_admissions[data.inboxID]
      if admission then
        admission.delivered_serial = serial
        local terminal = observation._v2_last_terminal
        if terminal and terminal.serial > serial then
          settle_waiters(observation, terminal)
        end
      end
    end
  elseif event.type == 'session.inbox.delivery.changed' then
    local item = state.inbox.items_by_id[data.inboxID]
    if not item or (data.delivery ~= 'steer' and data.delivery ~= 'queue') then
      record_diagnostic(observation, 'inbox', 'session.inbox.delivery.changed cannot identify a pending item')
      return false
    end
    item.delivery = data.delivery
  else
    return false
  end
  state.sync.inbox = { state = 'current' }
  return true
end

local function permission_event(observation, event)
  if event.type == 'permission.asked' then
    local data = event_identity(observation, event, 'permissions')
    if data == nil or data == false then
      return false
    end
    local request = permission_fact(data)
    local terminal = observation._v2_permission_terminal[request.id]
    if terminal then
      request.status = 'answered'
      request.answer = terminal.answer
    end
    observation:read().permission_requests_by_id[request.id] = request
  elseif event.type == 'permission.replied' then
    local data = event_identity(observation, event, 'permissions')
    if data == nil or data == false or type(data.requestID) ~= 'string' then
      if data then
        record_diagnostic(observation, 'permissions', 'permission.replied is missing requestID')
      end
      return false
    end
    observation._v2_permission_terminal[data.requestID] = { answer = data.reply }
    local request = observation:read().permission_requests_by_id[data.requestID]
    if request then
      request.status = 'answered'
      request.answer = data.reply
    end
  else
    return false
  end
  observation:read().sync.permissions = { state = 'current' }
  return true
end

local function question_event(observation, event)
  local data
  if event.type == 'form.created' then
    if type(event.data) ~= 'table' or type(event.data.form) ~= 'table' then
      record_diagnostic(observation, 'questions', 'form.created is missing form')
      return false
    end
    data = event.data.form
    if data.sessionID ~= observation._session_id then
      return false
    end
    local form = question_fact(data)
    local terminal = observation._v2_question_terminal[form.id]
    if terminal then
      form.status = terminal.status
      form.answers = vim.deepcopy(terminal.answers)
    end
    observation:read().question_requests_by_id[form.id] = form
  elseif event.type == 'form.replied' or event.type == 'form.cancelled' then
    data = event_identity(observation, event, 'questions')
    if data == nil or data == false or type(data.id) ~= 'string' then
      if data then
        record_diagnostic(observation, 'questions', event.type .. ' is missing form id')
      end
      return false
    end
    local terminal = {
      status = event.type == 'form.replied' and 'answered' or 'cancelled',
      answers = event.type == 'form.replied' and vim.deepcopy(data.answer) or nil,
    }
    observation._v2_question_terminal[data.id] = terminal
    local form = observation:read().question_requests_by_id[data.id]
    if form then
      form.status = terminal.status
      form.answers = terminal.answers
    end
  else
    return false
  end
  observation:read().sync.questions = { state = 'current' }
  return true
end

local function session_event(observation, event)
  local data = event_identity(observation, event, 'session')
  if data == nil or data == false then
    return false
  end
  local state = observation:read()
  if event.type == 'session.created' then
    local info = vim.deepcopy(data)
    info.id = data.sessionID
    info.time = { created = event.created, updated = event.created }
    state.session = session_fact(info)
  elseif event.type == 'session.renamed' then
    if type(data.title) ~= 'string' then
      record_diagnostic(observation, 'session', 'session.renamed is missing title')
      return false
    end
    state.session.title = data.title
  elseif event.type == 'session.moved' then
    if type(data.location) ~= 'table' then
      record_diagnostic(observation, 'session', 'session.moved is missing location')
      return false
    end
    state.session.location = vim.deepcopy(data.location)
    state.session.projectID = data.projectID
    state.session.subpath = data.subpath
  elseif event.type == 'session.usage.updated' then
    if type(data.cost) ~= 'number' then
      record_diagnostic(observation, 'session', 'session.usage.updated has invalid cost')
      return false
    end
    local ok, tokens = pcall(mapped_tokens, data.tokens)
    if not ok then
      record_diagnostic(observation, 'session', tostring(tokens))
      return false
    end
    state.session.cost = data.cost
    state.session.tokens = tokens
  elseif event.type == 'session.deleted' then
      state.sync.session = lifecycle.sync_error('session_deleted', 'session was deleted')
      return true
  else
    return false
  end
  state.sync.session = { state = 'current' }
  return true
end

local function children_event(observation, event)
  if
    event.type == 'session.created'
    and type(event.data) == 'table'
    and event.data.parentID == observation._session_id
  then
    local info = vim.deepcopy(event.data)
    info.id = info.sessionID
    info.time = { created = event.created, updated = event.created }
    put_child(observation:read().children, session_fact(info))
    observation:read().sync.children = { state = 'current' }
    return true
  elseif event.type == 'session.deleted' and type(event.data) == 'table' and type(event.data.sessionID) == 'string' then
    local children = observation:read().children
    if children.by_id[event.data.sessionID] then
      children.by_id[event.data.sessionID] = nil
      remove_from_order(children.order, event.data.sessionID)
      observation:read().sync.children = { state = 'current' }
      return true
    end
  end
  return false
end

local function file_event(observation, event)
  if
    event.type ~= 'filesystem.changed'
    and event.type ~= 'file.edited'
  then
    return false
  end
  local data = event.data
  if type(data) ~= 'table' or type(data.file) ~= 'string' then
    record_diagnostic(observation, 'files', event.type .. ' is missing file')
    return true
  end
  if data.event ~= nil and type(data.event) ~= 'string' then
    record_diagnostic(observation, 'files', event.type .. ' has invalid event')
    return true
  end
  local files = observation:read().files
  files.revision = files.revision + 1
  files.last = { path = data.file, event = data.event or 'change' }
  observation:read().sync.files = { state = 'current' }
  return true
end

local function route_event(connection, event)
  for _, observation in pairs(connection.observations) do
    local changed = {}
    if observation:_watches('children') and children_event(observation, event) then
      changed.children = true
    end
    if observation:_watches('files') and file_event(observation, event) then
      changed.files = true
    end
    if type(event.data) == 'table' and event.data.sessionID == observation._session_id then
      local local_operation_active = observation._local_operations > 0
      if observation:_watches('messages') then
        local previous_sync = observation:read().sync.messages
        if M.ingest_event(observation, event) or observation:read().sync.messages ~= previous_sync then
          changed.messages = true
        end
      end
      if (observation:_watches('inbox') or local_operation_active) and inbox_event(observation, event) then
        changed.inbox = true
      end
      if (observation:_watches('execution') or local_operation_active) and execution_event(observation, event) then
        changed.execution = true
      end
      if observation:_watches('permissions') and permission_event(observation, event) then
        changed.permissions = true
      end
      if observation:_watches('questions') and question_event(observation, event) then
        changed.questions = true
      end
      if observation:_watches('session') and session_event(observation, event) then
        changed.session = true
      end
    elseif observation:_watches('questions') and question_event(observation, event) then
      changed.questions = true
    end
    for resource in pairs(changed) do
      observation._event_revisions[resource] = observation._event_revisions[resource] + 1
      observation:_notify(resource)
      if resource ~= 'files' and observation:read().sync[resource].state == 'error' then
        observation:_start_resource(resource)
      end
    end
  end
end

local function resolved(value)
  return Promise.new():resolve(value)
end

local function ensure_session_location(observation)
  local session = observation:read().session
  if
    type(session.location) == 'table'
    and type(session.location.directory) == 'string'
    and type(session.projectID) == 'string'
    and type(session.time) == 'table'
  then
    return resolved(session)
  end
  return observation._connection.operations
    .get_session(observation._connection, observation._session_id, nil)
    :and_then(function(value)
      local mapped = session_fact(value)
      if mapped.id ~= observation._session_id then
        fail('session location belongs to another session')
      end
      observation:read().session = mapped
      return mapped
    end)
end

local function list_children(observation)
  local connection = observation._connection
  return ensure_session_location(observation):and_then(function(session)
    local items = {}
    local function page(cursor)
      return connection.operations
        .list_sessions(connection, session.location, cursor, 100, nil, nil)
        :and_then(function(result)
          if type(result) ~= 'table' or type(result.data) ~= 'table' or type(result.cursor) ~= 'table' then
            fail('invalid session page')
          end
          for _, info in ipairs(result.data) do
            if type(info) == 'table' and info.parentID == observation._session_id then
              items[#items + 1] = info
            end
          end
          if result.cursor.next then
            return page(result.cursor.next)
          end
          return items
        end)
    end
    return page(nil)
  end)
end

local function location_list(observation, operation)
  return ensure_session_location(observation):and_then(function(session)
    return operation(observation._connection, session.location, nil, nil)
  end)
end

local function request_resource(observation, resource)
  local connection = observation._connection
  if resource == 'session' then
    return connection.operations.get_session(connection, observation._session_id, nil)
  elseif resource == 'children' then
    return list_children(observation)
  elseif resource == 'messages' then
    return connection.operations.list_messages(connection, observation._session_id, nil, 50, nil)
  elseif resource == 'inbox' then
    return connection.operations.list_inbox(connection, observation._session_id, nil)
  elseif resource == 'execution' then
    return connection.operations.list_active_sessions(connection)
  elseif resource == 'permissions' then
    return location_list(observation, connection.operations.list_permissions)
  elseif resource == 'questions' then
    return location_list(observation, connection.operations.list_questions)
  end
  fail('unsupported resource read: ' .. tostring(resource))
end

local function valid_answer(field, value)
  local function is_option(candidate)
    if type(field.options) ~= 'table' or #field.options == 0 then
      return true
    end
    for _, option in ipairs(field.options) do
      if type(option) == 'table' and option.value == candidate then
        return true
      end
    end
    return field.custom == true
  end

  if value == nil then
    return not field.required
  elseif field.type == 'string' then
    return type(value) == 'string' and is_option(value)
  elseif field.type == 'boolean' then
    return type(value) == 'boolean'
  elseif field.type == 'number' then
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
  elseif field.type == 'integer' then
    return type(value) == 'number' and value == value and value % 1 == 0
  elseif field.type == 'multiselect' then
    if type(value) ~= 'table' then
      return false
    end
    for _, selected in ipairs(value) do
      if type(selected) ~= 'string' or not is_option(selected) then
        return false
      end
    end
    return true
  end
  return false
end

local function start_action(observation, operation, ...)
  local finish = observation:_begin_local_operation()
  local ok, request = pcall(operation, observation._connection, ...)
  if not ok then
    finish()
    error(request, 0)
  end
  return request:finally(finish)
end

---@param connection table
---@param ref {id: string, location?: table}
---@return table
function M.new(connection, ref)
  local session = { id = ref.id }
  if ref.location ~= nil then
    if type(ref.location) ~= 'table' then
      error('V2 observe location must be a table')
    end
    session.location = vim.deepcopy(ref.location)
  end

  local state = lifecycle.new_state(session)
  local observation = lifecycle.attach(connection, session, state, {
    name = 'V2',
    local_resource = function(resource)
      return resource == 'files'
    end,
    request_resource = request_resource,
    apply_resource = apply_resource,
    route_event = route_event,
    on_release_resource = function(current, resource)
      if resource == 'messages' then
        current._v2_content_by_message = {}
        current._v2_older_cursor = nil
        current._v2_history_complete = false
      end
    end,
    on_stream_error = function(current, message)
      current._v2_stream_generation = current._v2_stream_generation + 1
      mark_admissions_unknown(current, message)
    end,
    on_close = function(current)
      current._v2_stream_generation = current._v2_stream_generation + 1
      mark_admissions_unknown(current, 'connection closed')
    end,
  })
  observation._v2_content_by_message = {}
  observation._v2_inbox_terminal = {}
  observation._v2_permission_terminal = {}
  observation._v2_question_terminal = {}
  observation._v2_delivered = {}
  observation._v2_admissions = {}
  observation._v2_stream_generation = 0
  observation._v2_event_serial = 0
  observation._v2_last_terminal = nil
  observation._v2_terminal_seen_since_start = false
  observation._v2_horizon_ambiguous = false
  observation._v2_execution_event_active = false
  observation._v2_older_cursor = nil
  observation._v2_history_complete = false
  observation._v2_older_loading = false

  function observation:submit(input)
    if type(input) ~= 'table' then
      fail('submit requires input')
    end
    local finish = self:_begin_local_operation()
    local ok, err = pcall(lifecycle.ensure_stream, connection, self)
    if not ok then
      finish()
      error(err, 0)
    end
    local stream_generation = self._v2_stream_generation
    local called, request = pcall(connection.operations.submit, connection, self._session_id, input, nil, nil)
    if not called then
      finish()
      error(request, 0)
    end
    local result = request:and_then(function(admission)
      if not self:_is_current() then
        fail('submit response arrived after Observation release')
      end
      if type(admission) ~= 'table' or type(admission.id) ~= 'string' then
        fail('invalid submit admission')
      end
      local record = {
        admission = vim.deepcopy(admission),
        delivered_serial = self._v2_delivered[admission.id],
        release = self:_begin_local_operation(),
        waiters = {},
      }
      self._v2_admissions[admission.id] = record
      local terminal = self._v2_last_terminal
      if self._v2_stream_generation ~= stream_generation then
        record.unknown = {
          kind = 'admission_unknown',
          message = 'V2 observation: admission_unknown: event stream continuity was lost during submit',
        }
      elseif self._v2_horizon_ambiguous then
        record.unknown = {
          kind = 'admission_unknown',
          message = 'V2 observation: admission_unknown: overlapping execution horizons',
        }
      elseif record.delivered_serial and terminal and terminal.serial > record.delivered_serial then
        record.terminal = terminal
      end
      if record.unknown then
        release_admission(self, record)
      end
      return { kind = 'accepted', input = vim.deepcopy(admission) }
    end)
    return result:finally(finish)
  end

  function observation:wait_until_idle()
    local selected_id
    local selected
    for id, admission in pairs(self._v2_admissions) do
      if not admission.claimed then
        if selected then
          return Promise.new():reject('V2 observation: multiple admissions cannot be assigned to one execution')
        end
        selected_id = id
        selected = admission
      end
    end
    if not selected then
      if self._v2_horizon_ambiguous then
        return Promise.new():reject('V2 observation: overlapping execution horizons')
      end
      return Promise.new():reject('V2 observation: no accepted admission to wait for')
    end
    selected.claimed = true
    if selected.unknown then
      release_admission(self, selected)
      self._v2_admissions[selected_id] = nil
      return Promise.new():reject(selected.unknown.message)
    end
    if selected.terminal then
      release_admission(self, selected)
      self._v2_admissions[selected_id] = nil
      return resolved({
        kind = 'session_idle',
        outcome = selected.terminal.outcome,
        idle_at = selected.terminal.idle_at,
        error = selected.terminal.error,
      })
    end
    local finish = self:_begin_local_operation()
    local ok, err = pcall(lifecycle.ensure_stream, connection, self)
    if not ok then
      finish()
      error(err, 0)
    end
    local waiter = Promise.new()
    selected.waiters[#selected.waiters + 1] = waiter
    return waiter:finally(finish)
  end

  ---True when the server still has message pages older than the cached
  ---window (v2 pages backwards through `cursor.next`).
  function observation:has_older_history()
    return self._v2_older_cursor ~= nil and not self._v2_history_complete
  end

  function observation:load_older()
    if self._v2_older_loading then
      fail('load_older is already in progress')
    end
    if self._v2_history_complete or not self._v2_older_cursor then
      return resolved(nil)
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
      if not self:_is_current() then
        fail('older messages arrived after Observation release')
      end
      if self._event_revisions.messages ~= revision then
        self:read().sync.messages = { state = 'stale' }
        self:_start_resource('messages')
        return
      end
      if type(page) ~= 'table' or type(page.data) ~= 'table' or type(page.cursor) ~= 'table' then
        fail('invalid older message page')
      end
      M.ingest_snapshot(self, page.data, true)
      self._v2_older_cursor = page.cursor.next
      self._v2_history_complete = page.cursor.next == nil
      self:_notify('messages')
    end)
    return request:finally(function()
      self._v2_older_loading = false
      finish()
    end)
  end

  ---Load every remaining older page until the cached history is complete.
  ---The paging loop lives here because the cursor and completion state are
  ---protocol details; callers only declare how much history they need.
  function observation:load_complete_history()
    local function pull()
      if not self:has_older_history() then
        return resolved(nil)
      end
      return self:load_older():and_then(pull)
    end
    return pull()
  end

  function observation:interrupt()
    return start_action(self, connection.operations.interrupt, self._session_id)
  end

  function observation:reply_permission(request_id, answer)
    local request = self:read().permission_requests_by_id[request_id]
    if not request or request.status ~= 'pending' or type(answer) ~= 'table' then
      fail('permission request is not pending')
    end
    local supported = false
    for _, choice in ipairs(request.choices) do
      supported = supported or choice.value == answer.choice
    end
    if not supported or (answer.message ~= nil and type(answer.message) ~= 'string') then
      fail('invalid permission answer')
    end
    return start_action(self, connection.operations.reply_permission, self._session_id, request_id, {
      reply = answer.choice,
      message = answer.message,
    })
  end

  function observation:reply_question(request_id, answers)
    local request = self:read().question_requests_by_id[request_id]
    if not request or request.status ~= 'pending' or request.unavailable_reason or type(answers) ~= 'table' then
      fail('question request is not answerable')
    end
    local known = {}
    for _, field in ipairs(request.fields) do
      known[field.key] = true
      if not valid_answer(field, answers[field.key]) then
        fail('invalid answer for question field ' .. field.key)
      end
    end
    for key in pairs(answers) do
      if not known[key] then
        fail('unknown question field ' .. tostring(key))
      end
    end
    return start_action(self, connection.operations.reply_question, self._session_id, request_id, answers)
  end

  function observation:reject_question(request_id)
    local request = self:read().question_requests_by_id[request_id]
    if not request or request.status ~= 'pending' then
      fail('question request is not pending')
    end
    return start_action(self, connection.operations.cancel_question, self._session_id, request_id)
  end
  return observation
end

---@param connection table
function M.close(connection)
  lifecycle.close(connection)
end

return M
