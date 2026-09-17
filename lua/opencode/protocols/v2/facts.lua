local util = require('opencode.util')

local function fail(message)
  error('V2 observation: ' .. message, 0)
end

---@param value any
---@return table|nil
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

---@param value any
---@return table|nil
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

---@param value any
---@return table|nil
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

---@param value table
---@return table
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

local function base_entry(session_id, info)
  if type(info) ~= 'table' or type(info.id) ~= 'string' or type(info.type) ~= 'string' then
    fail('invalid message info')
  end
  return {
    id = info.id,
    session_id = session_id,
    kind = info.type,
    time = mapped_time(info.time),
    content = {},
  }
end

---@param session_id string
---@param info table
---@return table|nil
local function mapped_message(session_id, info)
  local entry = base_entry(session_id, info)
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

---@param info table
---@return table
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

---@param item table
---@param status? string
---@return table
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

---@param request table
---@return table
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

---@param form table
---@return table
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

return {
  mapped_error = mapped_error,
  mapped_tokens = mapped_tokens,
  mapped_model = mapped_model,
  mapped_tool_result = mapped_tool_result,
  mapped_message = mapped_message,
  session_fact = session_fact,
  inbox_fact = inbox_fact,
  permission_fact = permission_fact,
  question_fact = question_fact,
}
