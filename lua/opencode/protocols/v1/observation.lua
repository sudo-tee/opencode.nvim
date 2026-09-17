local facts = require('opencode.protocols.v1.facts')
local prompt_from_content = facts.prompt_from_content
local valid_native_mention = facts.valid_native_mention
local mapped_mention = facts.mapped_mention
local mapped_content = facts.mapped_content
local entry_from_info = facts.entry_from_info
local mapped_message = facts.mapped_message
local session_fact = facts.session_fact
local permission_fact = facts.permission_fact
local question_fact = facts.question_fact

local lifecycle = require('opencode.protocols.observation')
local id = require('opencode.id')
local Promise = require('opencode.promise')
local util = require('opencode.util')

local M = {}
local native_event
local ingest_resource_event

local message_event_types = {
  ['message.updated'] = true,
  ['message.removed'] = true,
  ['message.part.updated'] = true,
  ['message.part.removed'] = true,
  ['message.part.delta'] = true,
}

local function route_event(connection, event)
  local decoded = native_event(event)
  local kind = decoded and decoded.type or nil
  for _, observation in pairs(connection.observations) do
    if message_event_types[kind] and observation:_watches('messages') then
      local previous_sync = observation:read().sync.messages
      local changed = M.ingest_event(observation, event)
      if changed or observation:read().sync.messages ~= previous_sync then
        observation._event_revisions.messages = observation._event_revisions.messages + 1
        observation:_notify('messages')
      end
    elseif not message_event_types[kind] then
      local resource = ingest_resource_event(observation, event)
      if resource then
        observation._event_revisions[resource] = observation._event_revisions[resource] + 1
        observation:_notify(resource)
        if observation:read().sync[resource].state == 'stale' then
          observation:_start_resource(resource)
        end
      end
    end
  end
end

local function fail(message)
  error('V1 observation: ' .. message, 0)
end

local function record_diagnostic(observation, message)
  observation:read().sync.messages = {
    state = 'error',
    error = { kind = 'protocol_contract', message = message },
  }
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

local function remove_from_order(order, id)
  for index, value in ipairs(order) do
    if value == id then
      table.remove(order, index)
      return
    end
  end
end

local function find_content(state, message_id, part_id)
  local entry = state.entries_by_id[message_id]
  if not entry then
    return nil
  end
  for index, content in ipairs(entry.content) do
    if content.id == part_id then
      return content, index, entry
    end
  end
  return nil, nil, entry
end

local function native_part_mention(part)
  if part.type == 'file' and type(part.source) == 'table' then
    return part.source.text
  elseif part.type == 'agent' then
    return part.source
  end
end

local function clear_unresolved_part(observation, message_id, part_id)
  local message = observation._v1_unresolved_mentions[message_id]
  if not message then
    return
  end
  message[part_id] = nil
  if not next(message) then
    observation._v1_unresolved_mentions[message_id] = nil
  end
end

local function store_unresolved_part(observation, part)
  local value = native_part_mention(part)
  if not valid_native_mention(value) then
    return
  end
  local messages = observation._v1_unresolved_mentions
  messages[part.messageID] = messages[part.messageID] or {}
  messages[part.messageID][part.id] = vim.deepcopy(value)
end

local function resolve_unresolved_mentions(observation, message_id, entry)
  local unresolved = observation._v1_unresolved_mentions[message_id]
  if not unresolved then
    return
  end
  local prompt = prompt_from_content(entry.content)
  if not prompt then
    return
  end
  local diagnostics = {}
  for part_id, value in pairs(unresolved) do
    local content = find_content(observation:read(), message_id, part_id)
    if content then
      local mention, diagnostic = mapped_mention(value, prompt)
      content.mention = mention
      if diagnostic then
        diagnostics[#diagnostics + 1] = diagnostic
      end
    end
    unresolved[part_id] = nil
  end
  observation._v1_unresolved_mentions[message_id] = nil
  if #diagnostics > 0 then
    record_diagnostic(observation, table.concat(diagnostics, '; '))
  end
end

---@param observation table
---@param messages table[]
function M.ingest_snapshot(observation, messages)
  if type(messages) ~= 'table' then
    fail('snapshot must be a message list')
  end
  local state = observation:read()
  local mapped, diagnostics, seen = {}, {}, {}
  for _, message in ipairs(messages) do
    local entry, entry_diagnostics = mapped_message(message, state.session.location)
    if entry.session_id ~= state.session.id then
      fail('snapshot contains another session')
    end
    if seen[entry.id] then
      fail('snapshot contains a duplicate message')
    end
    seen[entry.id] = true
    mapped[#mapped + 1] = entry
    vim.list_extend(diagnostics, entry_diagnostics)
  end
  local entries, order = {}, {}
  for _, entry in ipairs(mapped) do
    entries[entry.id] = replace_entry(state.entries_by_id[entry.id], entry)
    order[#order + 1] = entry.id
  end
  state.entries_by_id = entries
  state.entry_order = order
  observation._v1_unresolved_mentions = {}
  state.sync.messages = #diagnostics == 0 and { state = 'current' }
    or { state = 'error', error = { kind = 'protocol_contract', message = table.concat(diagnostics, '; ') } }
end

local message_events = {
  ['message.updated'] = true,
  ['message.removed'] = true,
  ['message.part.updated'] = true,
  ['message.part.removed'] = true,
  ['message.part.delta'] = true,
}

native_event = function(event)
  if type(event) ~= 'table' or type(event.payload) ~= 'table' then
    return nil, 'invalid global event envelope'
  end
  local payload = event.payload
  if payload.type == 'sync' then
    local synced = payload.syncEvent
    if type(synced) ~= 'table' or type(synced.type) ~= 'string' or type(synced.data) ~= 'table' then
      return nil, 'invalid global sync event'
    end
    return { type = synced.type:gsub('%.%d+$', ''), properties = synced.data }
  end
  if type(payload.type) ~= 'string' or type(payload.properties) ~= 'table' then
    return nil, 'invalid global event payload'
  end
  return { type = payload.type, properties = payload.properties }
end

---@param observation table
---@param event table
---@return boolean changed
function M.ingest_event(observation, event)
  local decoded, diagnostic = native_event(event)
  if not decoded then
    record_diagnostic(observation, diagnostic)
    return false
  end
  if not message_events[decoded.type] then
    return false
  end
  local state = observation:read()
  if type(event.directory) ~= 'string' then
    record_diagnostic(observation, decoded.type .. ' is missing directory')
    return false
  end
  if event.directory ~= state.session.location.directory then
    return false
  end
  local properties = decoded.properties
  if type(properties.sessionID) ~= 'string' then
    record_diagnostic(observation, decoded.type .. ' is missing sessionID')
    return false
  end
  if properties.sessionID ~= state.session.id then
    return false
  end
  if decoded.type == 'message.updated' then
    local ok, entry = pcall(entry_from_info, properties.info, {})
    if not ok then
      record_diagnostic(observation, tostring(entry))
      return false
    end
    if entry.session_id ~= state.session.id then
      record_diagnostic(observation, 'message.updated contains another session')
      return false
    end
    local existing = state.entries_by_id[entry.id]
    entry.content = existing and existing.content or {}
    state.entries_by_id[entry.id] = replace_entry(existing, entry)
    if not existing then
      state.entry_order[#state.entry_order + 1] = entry.id
    end
    return true
  elseif decoded.type == 'message.removed' then
    if type(properties.messageID) ~= 'string' then
      record_diagnostic(observation, 'message.removed is missing messageID')
      return false
    end
    state.entries_by_id[properties.messageID] = nil
    remove_from_order(state.entry_order, properties.messageID)
    observation._v1_unresolved_mentions[properties.messageID] = nil
    return true
  end
  local message_id = decoded.type == 'message.part.updated'
      and type(properties.part) == 'table'
      and properties.part.messageID
    or properties.messageID
  if
    type(message_id) ~= 'string' or (decoded.type ~= 'message.part.updated' and type(properties.partID) ~= 'string')
  then
    record_diagnostic(observation, decoded.type .. ' is missing part identity')
    return false
  end
  if decoded.type == 'message.part.removed' then
    local _, index, entry = find_content(state, message_id, properties.partID)
    if index then
      table.remove(entry.content, index)
    end
    clear_unresolved_part(observation, message_id, properties.partID)
    return index ~= nil
  elseif decoded.type == 'message.part.delta' then
    local content = find_content(state, message_id, properties.partID)
    if
      not content
      or (content.kind ~= 'text' and content.kind ~= 'reasoning')
      or properties.field ~= 'text'
      or type(properties.delta) ~= 'string'
    then
      record_diagnostic(observation, 'message.part.delta cannot identify a text content')
      return false
    end
    content.text = content.text .. properties.delta
    return true
  end
  local entry = state.entries_by_id[message_id]
  if not entry then
    record_diagnostic(observation, 'message.part.updated has no message')
    return false
  end
  local ok, content, content_diagnostic, waiting =
    pcall(mapped_content, properties.part, prompt_from_content(entry.content), state.session.location)
  if not ok then
    record_diagnostic(observation, tostring(content))
    return false
  end
  if properties.part.messageID ~= message_id or properties.part.sessionID ~= state.session.id then
    record_diagnostic(observation, 'message.part.updated contains another message')
    return false
  end
  local _, index = find_content(state, message_id, content.id)
  if index then
    entry.content[index] = content
  else
    entry.content[#entry.content + 1] = content
  end
  if waiting then
    store_unresolved_part(observation, properties.part)
  else
    clear_unresolved_part(observation, message_id, content.id)
  end
  if content.kind == 'text' and not content.synthetic and not content.ignored then
    resolve_unresolved_mentions(observation, message_id, entry)
  end
  if content_diagnostic and not waiting then
    record_diagnostic(observation, content_diagnostic)
  end
  return true
end

local function apply_execution_status(state, status)
  if type(status) ~= 'table' or (status.type ~= 'busy' and status.type ~= 'retry' and status.type ~= 'idle') then
    fail('invalid session status')
  end
  if status.type == 'busy' then
    state.execution = { activity = 'running' }
  elseif status.type == 'retry' then
    state.execution = {
      activity = 'retrying',
      retry = {
        attempt = status.attempt,
        message = status.message,
        scheduled_at = status.next,
      },
    }
  else
    state.execution = { activity = 'idle' }
  end
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
    if type(value) ~= 'table' then
      fail('children snapshot must be a list')
    end
    local children = { by_id = {}, order = {} }
    for _, info in ipairs(value) do
      local child = session_fact(info)
      if child.parentID ~= state.session.id then
        fail('children snapshot contains another parent')
      end
      if children.by_id[child.id] then
        fail('children snapshot contains a duplicate session')
      end
      children.by_id[child.id] = child
      children.order[#children.order + 1] = child.id
    end
    state.children = children
  elseif resource == 'messages' then
    if type(value) ~= 'table' then
      fail('message snapshot must be a list')
    end
    M.ingest_snapshot(observation, value)
    observation._v1_history_complete = #value < 50
    observation._v1_history_limit = 50
  elseif resource == 'execution' then
    if type(value) ~= 'table' then
      fail('session status snapshot must be an object')
    end
    local status = value[state.session.id]
    if status == nil then
      state.execution = { activity = 'idle' }
    else
      apply_execution_status(state, status)
    end
  elseif resource == 'permissions' then
    if type(value) ~= 'table' then
      fail('permission snapshot must be a list')
    end
    local requests = {}
    for _, request in ipairs(value) do
      local mapped = permission_fact(request)
      if mapped.session_id == state.session.id then
        local terminal = observation._v1_permission_terminal[mapped.id]
        if terminal then
          mapped.status = 'answered'
          mapped.answer = terminal.reply
        end
        requests[mapped.id] = mapped
      end
    end
    state.permission_requests_by_id = requests
  elseif resource == 'questions' then
    if type(value) ~= 'table' then
      fail('question snapshot must be a list')
    end
    local requests = {}
    for _, request in ipairs(value) do
      local mapped = question_fact(request)
      if mapped.session_id == state.session.id then
        local terminal = observation._v1_question_terminal[mapped.id]
        if terminal then
          mapped.status = terminal.status
          mapped.answers = vim.deepcopy(terminal.answers)
        end
        requests[mapped.id] = mapped
      end
    end
    state.question_requests_by_id = requests
  else
    fail('unsupported resource read: ' .. tostring(resource))
  end
end

local function event_diagnostic(observation, resource, message)
  observation:read().sync[resource] = lifecycle.sync_error('protocol_contract', message)
  return resource
end

local function remove_child(children, child_id)
  if not children.by_id[child_id] then
    return false
  end
  children.by_id[child_id] = nil
  remove_from_order(children.order, child_id)
  return true
end

local function put_child(children, child)
  local exists = children.by_id[child.id] ~= nil
  children.by_id[child.id] = child
  if not exists then
    children.order[#children.order + 1] = child.id
  end
end

---@param observation table
---@param event table
---@return string|nil changed_resource
ingest_resource_event = function(observation, event)
  local decoded = native_event(event)
  if not decoded then
    return nil
  end
  local kind = decoded.type
  local properties = decoded.properties
  local state = observation:read()
  if kind == 'file.edited' or kind == 'file.watcher.updated' then
    if not observation:_watches('files') then
      return nil
    end
    if type(properties.file) ~= 'string' then
      return event_diagnostic(observation, 'files', kind .. ' is missing file')
    end
    if kind == 'file.watcher.updated' and properties.event ~= nil and type(properties.event) ~= 'string' then
      return event_diagnostic(observation, 'files', kind .. ' has invalid event')
    end
    state.files.revision = state.files.revision + 1
    state.files.last = { path = properties.file, event = properties.event or 'change' }
    state.sync.files = { state = 'current' }
    return 'files'
  end
  if type(event.directory) ~= 'string' then
    local resource = kind:match('^session%.') and 'session'
      or kind:match('^permission%.') and 'permissions'
      or kind:match('^question%.') and 'questions'
    if resource and observation:_watches(resource) then
      return event_diagnostic(observation, resource, kind .. ' is missing directory')
    end
    return nil
  end
  if event.directory ~= state.session.location.directory then
    return nil
  end

  if kind == 'session.created' or kind == 'session.updated' then
    local ok, session = pcall(session_fact, properties.info)
    if not ok then
      if observation:_watches('session') or observation:_watches('children') then
        return event_diagnostic(
          observation,
          observation:_watches('session') and 'session' or 'children',
          tostring(session)
        )
      end
      return nil
    end
    if type(properties.sessionID) ~= 'string' or properties.sessionID ~= session.id then
      return event_diagnostic(
        observation,
        observation:_watches('session') and 'session' or 'children',
        kind .. ' contains mismatched session identity'
      )
    end
    if observation:_watches('session') and session.id == state.session.id then
      state.session = session
      state.sync.session = { state = 'current' }
      return 'session'
    end
    if observation:_watches('children') then
      if session.parentID == state.session.id then
        put_child(state.children, session)
        state.sync.children = { state = 'current' }
        return 'children'
      elseif remove_child(state.children, session.id) then
        state.sync.children = { state = 'stale' }
        return 'children'
      end
    end
    return nil
  elseif kind == 'session.deleted' then
    if type(properties.sessionID) ~= 'string' then
      if observation:_watches('session') or observation:_watches('children') then
        return event_diagnostic(
          observation,
          observation:_watches('session') and 'session' or 'children',
          'session.deleted is missing sessionID'
        )
      end
      return nil
    end
    local ok, deleted = pcall(session_fact, properties.info)
    if not ok or deleted.id ~= properties.sessionID then
      if observation:_watches('session') or observation:_watches('children') then
        return event_diagnostic(
          observation,
          observation:_watches('session') and 'session' or 'children',
          'session.deleted contains invalid session info'
        )
      end
      return nil
    end
    if observation:_watches('session') and properties.sessionID == state.session.id then
      state.sync.session = lifecycle.sync_error('session_deleted', 'session was deleted')
      return 'session'
    end
    if observation:_watches('children') and remove_child(state.children, properties.sessionID) then
      state.sync.children = { state = 'current' }
      return 'children'
    end
    return nil
  elseif kind == 'session.status' or kind == 'session.idle' then
    if not observation:_watches('execution') then
      return nil
    end
    if type(properties.sessionID) ~= 'string' then
      return event_diagnostic(observation, 'execution', kind .. ' is missing sessionID')
    end
    if properties.sessionID ~= state.session.id then
      return nil
    end
    local status = kind == 'session.idle' and { type = 'idle' } or properties.status
    local ok, err = pcall(apply_execution_status, state, status)
    if not ok then
      return event_diagnostic(observation, 'execution', tostring(err))
    end
    state.sync.execution = { state = 'current' }
    return 'execution'
  elseif kind == 'permission.asked' then
    if not observation:_watches('permissions') then
      return nil
    end
    local ok, request = pcall(permission_fact, properties)
    if not ok then
      return event_diagnostic(observation, 'permissions', tostring(request))
    end
    if request.session_id ~= state.session.id then
      return nil
    end
    local terminal = observation._v1_permission_terminal[request.id]
    if terminal then
      request.status = 'answered'
      request.answer = terminal.reply
    end
    state.permission_requests_by_id[request.id] = request
    state.sync.permissions = { state = 'current' }
    return 'permissions'
  elseif kind == 'permission.replied' then
    if not observation:_watches('permissions') then
      return nil
    end
    if type(properties.sessionID) ~= 'string' or type(properties.requestID) ~= 'string' then
      return event_diagnostic(observation, 'permissions', 'permission.replied is missing request identity')
    end
    if properties.sessionID ~= state.session.id then
      return nil
    end
    observation._v1_permission_terminal[properties.requestID] = { reply = properties.reply }
    local request = state.permission_requests_by_id[properties.requestID]
    if request then
      request.status = 'answered'
      request.answer = properties.reply
    end
    return 'permissions'
  elseif kind == 'question.asked' then
    if not observation:_watches('questions') then
      return nil
    end
    local ok, request = pcall(question_fact, properties)
    if not ok then
      return event_diagnostic(observation, 'questions', tostring(request))
    end
    if request.session_id ~= state.session.id then
      return nil
    end
    local terminal = observation._v1_question_terminal[request.id]
    if terminal then
      request.status = terminal.status
      request.answers = vim.deepcopy(terminal.answers)
    end
    state.question_requests_by_id[request.id] = request
    state.sync.questions = { state = 'current' }
    return 'questions'
  elseif kind == 'question.replied' or kind == 'question.rejected' then
    if not observation:_watches('questions') then
      return nil
    end
    if type(properties.sessionID) ~= 'string' or type(properties.requestID) ~= 'string' then
      return event_diagnostic(observation, 'questions', kind .. ' is missing request identity')
    end
    if properties.sessionID ~= state.session.id then
      return nil
    end
    observation._v1_question_terminal[properties.requestID] = {
      status = kind == 'question.replied' and 'answered' or 'rejected',
      answers = kind == 'question.replied' and vim.deepcopy(properties.answers) or nil,
    }
    local request = state.question_requests_by_id[properties.requestID]
    if request then
      request.status = kind == 'question.replied' and 'answered' or 'rejected'
      request.answers = kind == 'question.replied' and vim.deepcopy(properties.answers) or nil
    end
    return 'questions'
  end
  return nil
end

local function request_resource(observation, resource)
  local connection = observation._connection
  local session_id = observation._session_id
  local location = observation:read().session.location
  if resource == 'session' then
    return connection.operations.get_session(connection, session_id, location)
  elseif resource == 'children' then
    return connection.operations.list_children(connection, session_id, location)
  elseif resource == 'messages' then
    return connection.operations.list_messages(connection, session_id, location, 50)
  elseif resource == 'execution' then
    return connection.operations.list_session_status(connection, location)
  elseif resource == 'permissions' then
    return connection.operations.list_permissions(connection, location)
  elseif resource == 'questions' then
    return connection.operations.list_questions(connection, location)
  end
  fail('unsupported resource read: ' .. tostring(resource))
end

local context_types = {
  selection = 'selection',
  diagnostics = 'diagnostics',
  cursor = 'cursor-data',
  buffer = 'file-content',
  git_diff = 'git-diff',
}

local function native_mention(text, mention)
  if mention == nil then
    return nil
  end
  if
    type(mention) ~= 'table'
    or type(mention.start_byte) ~= 'number'
    or type(mention.end_byte) ~= 'number'
    or mention.start_byte % 1 ~= 0
    or mention.end_byte % 1 ~= 0
    or mention.start_byte < 0
    or mention.end_byte < mention.start_byte
    or mention.end_byte > #text
  then
    fail('invalid input mention')
  end
  local start = util.utf16_index_from_byte(text, mention.start_byte)
  local finish = util.utf16_index_from_byte(text, mention.end_byte)
  if
    not start
    or not finish
    or util.byte_index_from_utf16(text, start) ~= mention.start_byte
    or util.byte_index_from_utf16(text, finish) ~= mention.end_byte
  then
    fail('input mention must use UTF-8 codepoint boundaries')
  end
  return {
    value = text:sub(mention.start_byte + 1, mention.end_byte),
    start = start,
    ['end'] = finish,
  }
end

local function submit_parts(input)
  if
    type(input) ~= 'table'
    or type(input.text) ~= 'string'
    or type(input.context) ~= 'table'
    or type(input.files) ~= 'table'
    or type(input.agents) ~= 'table'
  then
    fail('submit requires text, context, files, and agents')
  end
  local parts = {}
  for _, context in ipairs(input.context) do
    if
      type(context) ~= 'table'
      or type(context.text) ~= 'string'
      or type(context.source) ~= 'table'
      or not context_types[context.source.kind]
    then
      fail('invalid submit context')
    end
    local metadata = { context_type = context_types[context.source.kind] }
    if context.source.file_name ~= nil then
      if type(context.source.file_name) ~= 'string' then
        fail('invalid context file name')
      end
      metadata.filename = context.source.file_name
    end
    if context.source.range ~= nil then
      if type(context.source.range) ~= 'string' then
        fail('invalid context range')
      end
      metadata.range = context.source.range
    end
    parts[#parts + 1] = { type = 'text', text = context.text, synthetic = true, metadata = metadata }
  end
  for _, file in ipairs(input.files) do
    if type(file) ~= 'table' or type(file.media_type) ~= 'string' or file.media_type == '' then
      fail('invalid submit file')
    end
    if (file.bytes == nil) == (file.server_uri == nil) then
      fail('submit file requires exactly one of bytes or server_uri')
    end
    local url
    if file.bytes ~= nil then
      if type(file.bytes) ~= 'string' then
        fail('invalid submit file bytes')
      end
      if file.mention ~= nil then
        fail('V1 cannot attach a mention to bytes without a server file identity')
      end
      url = 'data:' .. file.media_type .. ';base64,' .. vim.base64.encode(file.bytes)
    else
      if type(file.server_uri) ~= 'string' or not file.server_uri:match('^file:///') then
        fail('V1 submit server_uri must be an absolute file URI')
      end
      url = file.server_uri
    end
    local source
    if file.mention then
      source = {
        type = 'file',
        path = file.server_uri:sub(8),
        text = native_mention(input.text, file.mention),
      }
    end
    parts[#parts + 1] = {
      type = 'file',
      mime = file.media_type,
      filename = file.name,
      url = url,
      source = source,
    }
  end
  for _, agent in ipairs(input.agents) do
    if type(agent) ~= 'table' or type(agent.name) ~= 'string' or agent.name == '' then
      fail('invalid submit agent')
    end
    parts[#parts + 1] = {
      type = 'agent',
      name = agent.name,
      source = native_mention(input.text, agent.mention),
    }
  end
  parts[#parts + 1] = { type = 'text', text = input.text }
  return parts
end

local function ingest_message(observation, message)
  local state = observation:read()
  local entry, diagnostics = mapped_message(message, state.session.location)
  if entry.session_id ~= state.session.id then
    fail('submit response belongs to another session')
  end
  local existing = state.entries_by_id[entry.id]
  state.entries_by_id[entry.id] = replace_entry(existing, entry)
  if not existing then
    state.entry_order[#state.entry_order + 1] = entry.id
  end
  observation._v1_unresolved_mentions[entry.id] = nil
  state.sync.messages = #diagnostics == 0 and { state = 'current' }
    or { state = 'error', error = { kind = 'protocol_contract', message = table.concat(diagnostics, '; ') } }
  return state.entries_by_id[entry.id]
end

local function merge_older(observation, messages)
  if type(messages) ~= 'table' then
    fail('older messages must be a list')
  end
  local state = observation:read()
  local mapped, diagnostics, seen = {}, {}, {}
  for _, message in ipairs(messages) do
    local entry, entry_diagnostics = mapped_message(message, state.session.location)
    if entry.session_id ~= state.session.id then
      fail('older messages contain another session')
    end
    if seen[entry.id] then
      fail('older messages contain a duplicate message')
    end
    seen[entry.id] = true
    mapped[#mapped + 1] = entry
    vim.list_extend(diagnostics, entry_diagnostics)
  end
  local prefix = {}
  for _, entry in ipairs(mapped) do
    if not state.entries_by_id[entry.id] then
      state.entries_by_id[entry.id] = entry
      prefix[#prefix + 1] = entry.id
    end
  end
  if #prefix > 0 then
    vim.list_extend(prefix, state.entry_order)
    state.entry_order = prefix
  end
  state.sync.messages = #diagnostics == 0 and { state = 'current' }
    or { state = 'error', error = { kind = 'protocol_contract', message = table.concat(diagnostics, '; ') } }
end

local function response_is_terminal(response)
  local info = response.info
  if type(info.time) ~= 'table' or type(info.time.completed) ~= 'number' then
    return false
  end
  if info.error ~= nil then
    return true
  end
  if type(info.finish) ~= 'string' or info.finish == '' or info.finish == 'tool-calls' or info.finish == 'unknown' then
    return false
  end
  for _, part in ipairs(response.parts) do
    if part.type == 'tool' then
      local provider_executed = type(part.metadata) == 'table' and part.metadata.providerExecuted == true
      local interrupted = type(part.state) == 'table'
        and part.state.status == 'error'
        and type(part.state.metadata) == 'table'
        and part.state.metadata.interrupted == true
      if not provider_executed and not interrupted then
        return false
      end
    end
  end
  return true
end

---@param connection table
function M.close(connection)
  lifecycle.close(connection)
end

local function clear_unresolved_mentions(observation)
  observation._v1_unresolved_mentions = {}
end

---@param connection table
---@param ref {id: string, location?: table}
---@return table
function M.new(connection, ref)
  if type(ref.location) ~= 'table' or type(ref.location.directory) ~= 'string' or ref.location.directory == '' then
    error('V1 observe requires the session location')
  end

  local session = { id = ref.id, location = vim.deepcopy(ref.location) }
  local state = lifecycle.new_state(session, { inbox = 'V1 has no session inbox contract' })
  local observation = lifecycle.attach(connection, session, state, {
    name = 'V1',
    operations_need_stream = false,
    stream_resource = function(resource)
      return resource ~= 'inbox'
    end,
    local_resource = function(resource)
      return resource == 'files'
    end,
    request_resource = request_resource,
    apply_resource = apply_resource,
    route_event = route_event,
    on_release_resource = function(current, resource)
      if resource == 'messages' then
        clear_unresolved_mentions(current)
      end
    end,
    on_unused = clear_unresolved_mentions,
    on_close = clear_unresolved_mentions,
  })
  observation._v1_permission_terminal = {}
  observation._v1_question_terminal = {}
  observation._v1_unresolved_mentions = {}
  observation._v1_history_complete = false
  observation._v1_history_limit = 50
  observation._v1_older_loading = false
  function observation:submit(input, opts)
    opts = opts or {}
    if input and input.model ~= nil then
      if
        type(input.model) ~= 'table'
        or type(input.model.providerID) ~= 'string'
        or type(input.model.modelID) ~= 'string'
      then
        fail('invalid submit model')
      end
    end
    for _, option in ipairs({ 'agent', 'variant', 'system' }) do
      if input and input[option] ~= nil and type(input[option]) ~= 'string' then
        fail('invalid submit ' .. option)
      end
    end
    local message_id = id.ascending('message')
    local body = {
      messageID = message_id,
      model = vim.deepcopy(input and input.model),
      agent = input and input.agent,
      variant = input and input.variant,
      system = input and input.system,
      parts = submit_parts(input),
    }
    local finish = self:_begin_local_operation()
    local operation = opts.async and connection.operations.submit_async or connection.operations.submit
    if type(operation) ~= 'function' then
      finish()
      fail('submit async is not supported')
    end
    local ok, request = pcall(operation, connection, self._session_id, self._session_ref.location, body)
    if not ok then
      finish()
      error(request, 0)
    end
    local result = request:and_then(function(response)
      if not self:_is_current() then
        fail('submit response arrived after Observation release')
      end
      if opts.async then
        if response ~= true then
          fail('invalid async submit response')
        end
        return { kind = 'accepted', input = { id = message_id } }
      end
      if type(response) ~= 'table' or type(response.info) ~= 'table' or type(response.parts) ~= 'table' then
        fail('invalid submit response')
      end
      if response.info.sessionID ~= self._session_id then
        fail('submit response belongs to another session')
      end
      local entry = ingest_message(self, response)
      self:_notify('messages')
      if
        response.info.role == 'assistant'
        and response.info.parentID == message_id
        and response_is_terminal(response)
      then
        return { kind = 'reply', message = entry, input_id = message_id }
      end
      return { kind = 'accepted', input = { id = message_id } }
    end)
    return result:finally(finish)
  end

  function observation:load_older()
    if self._v1_older_loading then
      fail('load_older is already in progress')
    end
    if self._v1_history_complete then
      return Promise.new():resolve(nil)
    end
    self._v1_older_loading = true
    local finish = self:_begin_local_operation()
    local requested_limit = self._v1_history_limit + 50
    local function read_page()
      local event_revision = self._event_revisions.messages
      return connection.operations
        .list_messages(connection, self._session_id, self._session_ref.location, requested_limit)
        :and_then(function(messages)
          if not self:_is_current() then
            fail('older messages arrived after Observation release')
          end
          if self._event_revisions.messages ~= event_revision then
            self:read().sync.messages = { state = 'stale' }
            self:_notify('messages')
            return read_page()
          end
          merge_older(self, messages)
          self._v1_history_limit = requested_limit
          self._v1_history_complete = #messages < requested_limit
          self:_notify('messages')
        end)
    end
    local ok, result = pcall(read_page)
    if not ok then
      self._v1_older_loading = false
      finish()
      error(result, 0)
    end
    return result:finally(function()
      self._v1_older_loading = false
      finish()
    end)
  end

  ---Load every remaining older page until the cached history is complete.
  ---The paging loop lives here because the limit and completion state are
  ---protocol details; callers only declare how much history they need.
  function observation:load_complete_history()
    local function pull()
      if self._v1_history_complete then
        return Promise.new():resolve(nil)
      end
      return self:load_older():and_then(pull)
    end
    return pull()
  end

  function observation:interrupt()
    return self:_start_action(connection.operations.interrupt, self._session_id, self._session_ref.location)
  end

  function observation:reply_permission(request_id, answer)
    local request_fact = self:read().permission_requests_by_id[request_id]
    if not request_fact or request_fact.status ~= 'pending' or type(answer) ~= 'table' then
      fail('permission request is not pending')
    end
    if
      (answer.choice ~= 'once' and answer.choice ~= 'always' and answer.choice ~= 'reject')
      or (answer.message ~= nil and type(answer.message) ~= 'string')
    then
      fail('invalid permission answer')
    end
    return self:_start_action(connection.operations.reply_permission, request_id, self._session_ref.location, {
      reply = answer.choice,
      message = answer.message,
    })
  end

  function observation:reply_question(request_id, answers)
    local request = self:read().question_requests_by_id[request_id]
    if not request or request.status ~= 'pending' or type(answers) ~= 'table' then
      fail('question request is not pending')
    end
    local native_answers = {}
    for index, field in ipairs(request.fields) do
      local answer = answers[field.key]
      if field.type == 'multiselect' then
        if type(answer) ~= 'table' then
          fail('question answer ' .. field.key .. ' must be a string list')
        end
        native_answers[index] = {}
        for _, value in ipairs(answer) do
          if type(value) ~= 'string' then
            fail('question answer ' .. field.key .. ' must be a string list')
          end
          native_answers[index][#native_answers[index] + 1] = value
        end
      else
        if type(answer) ~= 'string' then
          fail('question answer ' .. field.key .. ' must be a string')
        end
        native_answers[index] = { answer }
      end
    end
    return self:_start_action(
      connection.operations.reply_question,
      request_id,
      self._session_ref.location,
      native_answers
    )
  end

  function observation:reject_question(request_id)
    local request_fact = self:read().question_requests_by_id[request_id]
    if not request_fact or request_fact.status ~= 'pending' then
      fail('question request is not pending')
    end
    return self:_start_action(connection.operations.reject_question, request_id, self._session_ref.location)
  end

  return observation
end

return M
