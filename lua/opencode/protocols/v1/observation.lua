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

local function mapped_error(value)
  if value == nil then
    return nil
  end
  if type(value) == 'string' then
    return { message = value }
  end
  if type(value) ~= 'table' then
    fail('invalid error')
  end
  local data = type(value.data) == 'table' and value.data or value
  return {
    type = value.name or value.type,
    message = data.message,
    status = data.statusCode or data.status,
    retryable = data.isRetryable,
    provider_id = data.providerID,
    ref = data.ref,
    retries = data.retries,
    response_body = data.responseBody,
  }
end

local function mapped_time(value)
  if value == nil then
    return nil
  end
  if type(value) ~= 'table' then
    fail('invalid time')
  end
  return vim.deepcopy(value)
end

local function mapped_content_time(value)
  if value == nil then
    return nil
  end
  if type(value) ~= 'table' or type(value.start) ~= 'number' then
    fail('invalid content time')
  end
  return { started = value.start, completed = value['end'] }
end

local function context_content(part)
  local metadata = part.metadata
  local context_type = type(metadata) == 'table' and metadata.context_type or nil
  if context_type == nil then
    return nil
  end

  local base = { id = part.id, kind = 'editor_context', synthetic = part.synthetic, ignored = part.ignored }
  if context_type == 'file-content' then
    base.source = { kind = 'buffer', file_name = metadata.filename, media_type = metadata.mime }
    base.text = part.text
    return base
  end
  if context_type == 'git-diff' then
    base.source = { kind = 'git_diff' }
    base.text = part.text
    return base
  end
  if context_type ~= 'selection' and context_type ~= 'diagnostics' and context_type ~= 'cursor-data' then
    return nil, 'unsupported editor context type: ' .. tostring(context_type)
  end

  local ok, decoded = pcall(vim.json.decode, part.text)
  if not ok or type(decoded) ~= 'table' or decoded.context_type ~= context_type then
    return nil, 'invalid ' .. context_type .. ' editor context JSON'
  end
  local file_name = type(decoded.file) == 'table' and (decoded.file.name or decoded.file.path) or nil
  if context_type == 'selection' then
    if type(decoded.content) ~= 'string' or (decoded.lines ~= nil and type(decoded.lines) ~= 'string') then
      return nil, 'invalid selection editor context'
    end
    base.source = { kind = 'selection', file_name = file_name, range = decoded.lines }
    base.text = decoded.content
    return base
  end
  if context_type == 'diagnostics' then
    if type(decoded.content) ~= 'table' then
      return nil, 'invalid diagnostics editor context'
    end
    local diagnostics = {}
    for _, item in ipairs(decoded.content) do
      if
        type(item) ~= 'table'
        or type(item.msg) ~= 'string'
        or type(item.severity) ~= 'number'
        or type(item.pos) ~= 'string'
      then
        return nil, 'invalid diagnostics editor context'
      end
      diagnostics[#diagnostics + 1] = { message = item.msg, severity = item.severity, position = item.pos }
    end
    base.source = { kind = 'diagnostics', file_name = file_name }
    base.diagnostics = diagnostics
    return base
  end

  if
    type(decoded.line) ~= 'number'
    or type(decoded.column) ~= 'number'
    or type(decoded.line_content) ~= 'string'
    or (decoded.lines_before ~= nil and type(decoded.lines_before) ~= 'table')
    or (decoded.lines_after ~= nil and type(decoded.lines_after) ~= 'table')
  then
    return nil, 'invalid cursor editor context'
  end
  base.source = { kind = 'cursor', file_name = file_name }
  base.line = decoded.line
  base.column = decoded.column
  base.line_content = decoded.line_content
  base.lines_before = vim.deepcopy(decoded.lines_before)
  base.lines_after = vim.deepcopy(decoded.lines_after)
  return base
end

local utf16_length = util.utf16_length

local function prompt_from_native_parts(parts)
  local prompt, prompt_length
  for _, part in ipairs(parts) do
    if part.type == 'text' and not part.synthetic and not part.ignored and type(part.text) == 'string' then
      local length = utf16_length(part.text)
      if length and (not prompt_length or length > prompt_length) then
        prompt = part.text
        prompt_length = length
      end
    end
  end
  return prompt
end

local function prompt_from_content(content)
  local prompt, prompt_length
  for _, part in ipairs(content) do
    if part.kind == 'text' and not part.synthetic and not part.ignored and type(part.text) == 'string' then
      local length = utf16_length(part.text)
      if length and (not prompt_length or length > prompt_length) then
        prompt = part.text
        prompt_length = length
      end
    end
  end
  return prompt
end

local byte_index_from_utf16 = util.byte_index_from_utf16

local function valid_native_mention(value)
  return type(value) == 'table'
    and type(value.value) == 'string'
    and type(value.start) == 'number'
    and type(value['end']) == 'number'
    and value.start % 1 == 0
    and value['end'] % 1 == 0
    and value.start >= 0
    and value['end'] >= value.start
end

local function mapped_mention(value, prompt)
  if value == nil then
    return nil
  end
  if not valid_native_mention(value) then
    return nil, 'invalid native mention'
  end
  if prompt == nil then
    return nil, 'native mention has no prompt text', true
  end
  if not util.is_utf16_boundary(prompt, value.start) or not util.is_utf16_boundary(prompt, value['end']) then
    return nil, 'native mention does not identify a prompt range'
  end
  local start_byte = byte_index_from_utf16(prompt, value.start)
  local end_byte = byte_index_from_utf16(prompt, value['end'])
  if not start_byte or not end_byte or prompt:sub(start_byte + 1, end_byte) ~= value.value then
    return nil, 'native mention does not identify a prompt range'
  end
  return { text = value.value, start_byte = start_byte, end_byte = end_byte }
end

local function mapped_file_source(value, prompt)
  if value == nil then
    return nil, nil
  end
  if type(value) ~= 'table' then
    fail('invalid file source')
  end
  local source
  if value.type == 'file' and type(value.path) == 'string' then
    source = { kind = 'file', path = value.path }
  elseif
    value.type == 'symbol'
    and type(value.path) == 'string'
    and type(value.name) == 'string'
    and type(value.range) == 'table'
  then
    source = { kind = 'symbol', path = value.path, name = value.name, range = vim.deepcopy(value.range) }
  elseif value.type == 'resource' and type(value.uri) == 'string' then
    source = { kind = 'resource', uri = value.uri }
  else
    fail('invalid file source')
  end
  local mention, diagnostic, waiting = mapped_mention(value.text, prompt)
  return source, mention, diagnostic, waiting
end

local function file_content(part, prompt)
  local source, mention, diagnostic, waiting = mapped_file_source(part.source, prompt)
  return {
    id = part.id,
    kind = 'file',
    uri = part.url,
    media_type = part.mime,
    name = part.filename,
    source = source,
    mention = mention,
  },
    diagnostic,
    waiting
end

local tool_states = { pending = true, running = true, completed = true, error = true }

local function tool_specialized_fields(part, location)
  local state = part.state
  local input = type(state.input) == 'table' and state.input or {}
  local metadata = type(state.metadata) == 'table' and state.metadata or {}
  local fields, diagnostics = {}, {}
  local diagnostic_prefix = 'tool ' .. part.callID .. ' '

  if type(input.command) == 'string' then
    fields.command = input.command
  end
  if type(input.description) == 'string' then
    fields.description = input.description
  end

  if type(input.filePath) == 'string' then
    fields.target = { path = input.filePath, location = vim.deepcopy(location) }
    if type(input.content) == 'string' then
      fields.target.content = input.content
    end
  end

  if metadata.files ~= nil then
    if type(metadata.files) ~= 'table' then
      diagnostics[#diagnostics + 1] = diagnostic_prefix .. 'files metadata is invalid'
    else
      local changes = {}
      for index, file in ipairs(metadata.files) do
        local path = type(file) == 'table' and (file.relativePath or file.filePath) or nil
        if type(path) ~= 'string' then
          diagnostics[#diagnostics + 1] = diagnostic_prefix .. 'file ' .. index .. ' has no path'
          changes = nil
          break
        end
        changes[#changes + 1] = {
          path = path,
          location = vim.deepcopy(location),
          diff = type(file.diff) == 'string' and file.diff or type(file.patch) == 'string' and file.patch or nil,
        }
      end
      fields.changes = changes
    end
  elseif type(metadata.diff) == 'string' and fields.target then
    fields.changes = {
      { path = fields.target.path, location = vim.deepcopy(location), diff = metadata.diff },
    }
  end

  if type(metadata.sessionId) == 'string' then
    fields.child_session = { id = metadata.sessionId, location = vim.deepcopy(location) }
  end

  local count = type(metadata.count) == 'number' and metadata.count
    or type(metadata.matches) == 'number' and metadata.matches
    or nil
  if count ~= nil or type(metadata.truncated) == 'boolean' then
    fields.search = { count = count }
    if type(metadata.truncated) == 'boolean' then
      fields.search.truncated = metadata.truncated
    end
  end

  if metadata.answers ~= nil then
    if type(metadata.answers) ~= 'table' or type(input.questions) ~= 'table' then
      diagnostics[#diagnostics + 1] = diagnostic_prefix .. 'question answers are invalid'
    else
      local answers = {}
      for index, question in ipairs(input.questions) do
        local values = metadata.answers[index]
        if type(question) ~= 'table' or type(values) ~= 'table' then
          diagnostics[#diagnostics + 1] = diagnostic_prefix .. 'question ' .. index .. ' has invalid answers'
          answers = nil
          break
        end
        for _, value in ipairs(values) do
          if type(value) ~= 'string' then
            diagnostics[#diagnostics + 1] = diagnostic_prefix .. 'question ' .. index .. ' has a non-string answer'
            answers = nil
            break
          end
        end
        if not answers then
          break
        end
        answers[#answers + 1] = {
          question = type(question.question) == 'string' and question.question or nil,
          header = type(question.header) == 'string' and question.header or nil,
          values = vim.deepcopy(values),
        }
      end
      fields.answers = answers
    end
  end

  if input.todos ~= nil then
    if type(input.todos) ~= 'table' then
      diagnostics[#diagnostics + 1] = diagnostic_prefix .. 'todos are invalid'
    else
      local todos = {}
      local states = { pending = true, in_progress = true, completed = true }
      for index, todo in ipairs(input.todos) do
        if type(todo) ~= 'table' or type(todo.content) ~= 'string' or not states[todo.status] then
          diagnostics[#diagnostics + 1] = diagnostic_prefix .. 'todo ' .. index .. ' is invalid'
          todos = nil
          break
        end
        todos[#todos + 1] = { text = todo.content, state = todo.status }
      end
      fields.todos = todos
    end
  end

  return fields, diagnostics
end

local function tool_content(part, prompt, location)
  local state = part.state
  if
    type(part.callID) ~= 'string'
    or type(part.tool) ~= 'string'
    or type(state) ~= 'table'
    or not tool_states[state.status]
  then
    fail('invalid tool state for part ' .. part.id)
  end
  local result
  local diagnostics = {}
  if state.status == 'completed' then
    result = { { kind = 'text', text = state.output } }
    for _, attachment in ipairs(state.attachments or {}) do
      local mapped, diagnostic = file_content(attachment, prompt)
      result[#result + 1] = mapped
      if diagnostic then
        diagnostics[#diagnostics + 1] = diagnostic
      end
    end
  end
  local time
  if type(state.time) == 'table' then
    time = { started = state.time.start, completed = state.time['end'], compacted = state.time.compacted }
  end
  local content = {
    id = part.id,
    kind = 'tool',
    call_id = part.callID,
    name = part.tool,
    title = state.title,
    state = state.status,
    input = vim.deepcopy(state.input),
    input_text = state.raw,
    result = result,
    error = state.status == 'error' and mapped_error(state.error) or nil,
    time = time,
  }
  if type(part.metadata) == 'table' and type(part.metadata.providerExecuted) == 'boolean' then
    content.executed = part.metadata.providerExecuted
  end
  local specialized, specialized_diagnostics = tool_specialized_fields(part, location)
  for key, value in pairs(specialized) do
    content[key] = value
  end
  vim.list_extend(diagnostics, specialized_diagnostics)
  return content, #diagnostics > 0 and table.concat(diagnostics, '; ') or nil
end

local function mapped_content(part, prompt, location)
  if
    type(part) ~= 'table'
    or type(part.id) ~= 'string'
    or type(part.sessionID) ~= 'string'
    or type(part.messageID) ~= 'string'
    or type(part.type) ~= 'string'
  then
    fail('invalid part identity')
  end
  if part.type == 'text' then
    local context, diagnostic = context_content(part)
    if context then
      return context
    end
    return {
      id = part.id,
      kind = 'text',
      text = part.text,
      synthetic = part.synthetic,
      ignored = part.ignored,
      time = mapped_content_time(part.time),
    },
      diagnostic
  elseif part.type == 'reasoning' then
    return { id = part.id, kind = 'reasoning', text = part.text, time = mapped_content_time(part.time) }
  elseif part.type == 'file' then
    return file_content(part, prompt)
  elseif part.type == 'agent' then
    local mention, diagnostic, waiting = mapped_mention(part.source, prompt)
    return {
      id = part.id,
      kind = 'agent',
      name = part.name,
      mention = mention,
    },
      diagnostic,
      waiting
  elseif part.type == 'tool' then
    return tool_content(part, prompt, location)
  elseif part.type == 'compaction' then
    return {
      id = part.id,
      kind = 'compaction',
      auto = part.auto,
      overflow = part.overflow,
      boundary = part.tail_start_id,
    }
  elseif part.type == 'subtask' then
    return {
      id = part.id,
      kind = 'subtask',
      prompt = part.prompt,
      description = part.description,
      agent = part.agent,
      model = vim.deepcopy(part.model),
      command = part.command,
    }
  elseif part.type == 'retry' then
    return {
      id = part.id,
      kind = 'retry',
      attempt = part.attempt,
      error = mapped_error(part.error),
      time = mapped_time(part.time),
    }
  elseif part.type == 'snapshot' then
    return { id = part.id, kind = 'snapshot', snapshot = part.snapshot }
  elseif part.type == 'patch' then
    return { id = part.id, kind = 'patch', hash = part.hash, files = vim.deepcopy(part.files) }
  elseif part.type == 'step-start' then
    return { id = part.id, kind = 'step_start', snapshot = part.snapshot }
  elseif part.type == 'step-finish' then
    return {
      id = part.id,
      kind = 'step_finish',
      reason = part.reason,
      snapshot = part.snapshot,
      cost = part.cost,
      tokens = vim.deepcopy(part.tokens),
    }
  end
  fail('unsupported part type: ' .. part.type)
end

local function entry_from_info(info, content)
  if
    type(info) ~= 'table'
    or type(info.id) ~= 'string'
    or type(info.sessionID) ~= 'string'
    or (info.role ~= 'user' and info.role ~= 'assistant')
    or type(info.time) ~= 'table'
    or type(info.time.created) ~= 'number'
  then
    fail('invalid message info')
  end
  local model = info.model
  if info.role == 'assistant' then
    model = { providerID = info.providerID, modelID = info.modelID, variant = info.variant }
  end
  return {
    id = info.id,
    session_id = info.sessionID,
    kind = info.role,
    time = vim.deepcopy(info.time),
    content = content,
    error = mapped_error(info.error),
    agent = info.mode or info.agent,
    model = vim.deepcopy(model),
    parent_message_id = info.parentID,
    finish = info.finish,
    cost = info.cost,
    tokens = vim.deepcopy(info.tokens),
  }
end

local function mapped_message(message, location)
  if type(message) ~= 'table' or type(message.info) ~= 'table' or type(message.parts) ~= 'table' then
    fail('invalid WithParts response')
  end
  local content, diagnostics = {}, {}
  local prompt = prompt_from_native_parts(message.parts)
  for _, part in ipairs(message.parts) do
    local mapped, diagnostic = mapped_content(part, prompt, location)
    if part.sessionID ~= message.info.sessionID or part.messageID ~= message.info.id then
      fail('part belongs to another message')
    end
    content[#content + 1] = mapped
    if diagnostic then
      diagnostics[#diagnostics + 1] = diagnostic
    end
  end
  return entry_from_info(message.info, content), diagnostics
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

local function session_fact(info)
  if
    type(info) ~= 'table'
    or type(info.id) ~= 'string'
    or type(info.slug) ~= 'string'
    or type(info.projectID) ~= 'string'
    or type(info.directory) ~= 'string'
    or type(info.title) ~= 'string'
    or type(info.version) ~= 'string'
    or type(info.time) ~= 'table'
    or type(info.time.created) ~= 'number'
    or type(info.time.updated) ~= 'number'
  then
    fail('invalid session info')
  end
  return {
    id = info.id,
    title = info.title,
    parentID = info.parentID,
    location = { directory = info.directory },
    projectID = info.projectID,
    subpath = info.path,
    slug = info.slug,
    version = info.version,
    agent = info.agent,
    model = vim.deepcopy(info.model),
    time = mapped_time(info.time),
    summary = vim.deepcopy(info.summary),
    share = vim.deepcopy(info.share),
  }
end

local function permission_fact(request)
  if type(request) ~= 'table' or type(request.id) ~= 'string' or type(request.sessionID) ~= 'string' then
    fail('invalid permission request')
  end
  if
    type(request.permission) ~= 'string'
    or type(request.patterns) ~= 'table'
    or type(request.metadata) ~= 'table'
    or type(request.always) ~= 'table'
  then
    fail('invalid permission request content')
  end
  for _, pattern in ipairs(request.patterns) do
    if type(pattern) ~= 'string' then
      fail('invalid permission pattern')
    end
  end
  for _, pattern in ipairs(request.always) do
    if type(pattern) ~= 'string' then
      fail('invalid permission always pattern')
    end
  end
  return {
    id = request.id,
    session_id = request.sessionID,
    permission = request.permission,
    patterns = vim.deepcopy(request.patterns),
    always = vim.deepcopy(request.always),
    tool = vim.deepcopy(request.tool),
    choices = {
      { value = 'once', label = 'Allow once', description = 'Allow this request once' },
      { value = 'always', label = 'Always allow', description = 'Save an allow rule' },
      { value = 'reject', label = 'Reject', description = 'Reject this request' },
    },
    status = 'pending',
  }
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

local function question_fact(request)
  if
    type(request) ~= 'table'
    or type(request.id) ~= 'string'
    or type(request.sessionID) ~= 'string'
    or type(request.questions) ~= 'table'
  then
    fail('invalid question request')
  end
  local fields = {}
  for index, question in ipairs(request.questions) do
    if
      type(question) ~= 'table'
      or type(question.question) ~= 'string'
      or type(question.header) ~= 'string'
      or type(question.options) ~= 'table'
    then
      fail('invalid question field')
    end
    local options = {}
    for _, option in ipairs(question.options) do
      if type(option) ~= 'table' or type(option.label) ~= 'string' or type(option.description) ~= 'string' then
        fail('invalid question option')
      end
      options[#options + 1] = { value = option.label, label = option.label, description = option.description }
    end
    fields[#fields + 1] = {
      key = tostring(index),
      prompt = question.question,
      title = question.header,
      type = question.multiple and 'multiselect' or 'string',
      options = options,
      custom = question.custom,
      required = true,
    }
  end
  return {
    id = request.id,
    session_id = request.sessionID,
    fields = fields,
    tool = vim.deepcopy(request.tool),
    status = 'pending',
  }
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
  function observation:submit(input)
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
    local message_id = id.descending('message')
    local body = {
      messageID = message_id,
      model = vim.deepcopy(input and input.model),
      agent = input and input.agent,
      variant = input and input.variant,
      system = input and input.system,
      parts = submit_parts(input),
    }
    local finish = self:_begin_local_operation()
    local ok, request = pcall(connection.operations.submit, connection, self._session_id, self._session_ref.location, body)
    if not ok then
      finish()
      error(request, 0)
    end
    local result = request:and_then(function(response)
      if not self:_is_current() then
        fail('submit response arrived after Observation release')
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
    local finish = self:_begin_local_operation()
    local ok, request = pcall(connection.operations.interrupt, connection, self._session_id, self._session_ref.location)
    if not ok then
      finish()
      error(request, 0)
    end
    return request:finally(finish)
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
    local finish = self:_begin_local_operation()
    local ok, request = pcall(connection.operations.reply_permission, connection, request_id, self._session_ref.location, {
      reply = answer.choice,
      message = answer.message,
    })
    if not ok then
      finish()
      error(request, 0)
    end
    return request:finally(finish)
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
    local finish = self:_begin_local_operation()
    local ok, promise =
      pcall(connection.operations.reply_question, connection, request_id, self._session_ref.location, native_answers)
    if not ok then
      finish()
      error(promise, 0)
    end
    return promise:finally(finish)
  end

  function observation:reject_question(request_id)
    local request_fact = self:read().question_requests_by_id[request_id]
    if not request_fact or request_fact.status ~= 'pending' then
      fail('question request is not pending')
    end
    local finish = self:_begin_local_operation()
    local ok, request = pcall(connection.operations.reject_question, connection, request_id, self._session_ref.location)
    if not ok then
      finish()
      error(request, 0)
    end
    return request:finally(finish)
  end

  return observation
end

return M
