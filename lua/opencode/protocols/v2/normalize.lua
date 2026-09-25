local util = require('opencode.util')
local log = require('opencode.log')
local v = require('opencode.shape')
local shared_decode_editor_context = require('opencode.protocols.observation').decode_editor_context

--- Returns the first key in `value` (from `keys`) that is non-nil.
local function first(value, keys)
  for _, key in ipairs(keys) do
    if value[key] ~= nil then
      return value[key]
    end
  end
end

--- Validates `value` against shorthand or explicit schemas. Errors from this
--- module get the same context prefix as the older inline guards.
local function shape(value, spec, message)
  local full_message = message and 'V2 observation: ' .. message or nil
  return v.validate(value, spec, full_message)
end

local mention_shape = v.object({
  start = v.integer():min(0),
  ['end'] = v.integer():min(0),
  text = 'string',
}):constraint(function(value)
  return value['end'] >= value.start
end, 'valid prompt mention')

local model_shape = v.object({ providerID = 'string', id = 'string' }):convert(function(value)
  return { providerID = value.providerID, modelID = value.id, variant = value.variant }
end)

local function inbox_shape(status)
  return v.object({
    id = 'string',
    sessionID = 'string',
    type = 'string',
    timeCreated = 'number',
    delivery = { 'steer', 'queue' },
  }):convert(function(item)
    return {
      id = item.id,
      session_id = item.sessionID,
      kind = item.type,
      delivery = item.delivery,
      status = status or 'pending',
      created_at_ms = item.timeCreated,
    }
  end)
end

local permission_shape = v.object({
  id = 'string',
  sessionID = 'string',
  action = 'string',
  resources = v.table(),
}):convert(function(request)
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
end)

local question_shape = v.object({
  id = 'string',
  sessionID = 'string',
  fields = v.array(v.object({ key = 'string', type = 'string' })),
}):convert(function(form)
  local fields, unavailable = {}, nil
  for _, field in ipairs(form.fields) do
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
end)

local file_source_shape = v.union(
  v.object({ type = v.literal('uri'), uri = 'string' }):convert(function(value)
    return { kind = 'resource', uri = value.uri }
  end),
  v.object({ type = v.literal('inline') }):transform(function()
    return nil
  end)
)

local file_shape = v.object({
  mime = 'string',
  data = 'string',
  source = file_source_shape,
})

local function numeric_shape(keys)
  local spec = {}
  for _, key in ipairs(keys) do
    spec[key] = v.optional('number')
  end
  return v.object(spec):convert(function(value)
    local result = {}
    for _, key in ipairs(keys) do
      if value[key] ~= nil then
        result[key] = value[key]
      end
    end
    return result
  end)
end

local message_time_shape = numeric_shape({ 'created', 'streamed', 'completed' })
local token_usage_shape = v.object({
  input = v.optional('number'),
  output = v.optional('number'),
  reasoning = v.optional('number'),
  cache = v.optional(numeric_shape({ 'read', 'write' })),
}):convert(function(value)
  local result = {}
  for _, key in ipairs({ 'input', 'output', 'reasoning', 'cache' }) do
    if value[key] ~= nil then
      result[key] = value[key]
    end
  end
  return result
end)

--- Fails with `message` unless `value` is one of `options`.
local function one_of(value, options, message)
  return v.enum(options):parse(value, 'V2 observation: ' .. message)
end

---@param value any
---@return table|nil
local function mapped_error(value)
  if value == nil then
    return nil
  end
  if type(value) ~= 'table' then
    return { message = tostring(value) }
  end
  local retryable = value.retryable
  if retryable == nil then
    retryable = value.isRetryable
  end
  local result = {
    type = first(value, { 'name', 'type', 'tag' }),
    message = value.message,
    status = first(value, { 'status', 'statusCode' }),
    retryable = retryable,
    provider_id = value.providerID,
    ref = value.ref,
    retries = value.retries,
  }
  if not next(result) then
    result.type = 'unknown'
  end
  return result
end

---@param value OpencodeV2MessageTime|nil
---@return OpencodeV2MessageTime|nil
local function mapped_time(value)
  if value == nil then
    return nil
  end
  local result = message_time_shape:parse(value, 'V2 observation: invalid message time')
  ---@cast result OpencodeV2MessageTime
  return result
end

---@param value OpencodeV2TokenUsage|nil
---@return OpencodeV2TokenUsage|nil
local function mapped_tokens(value)
  if value == nil then
    return nil
  end
  local result = token_usage_shape:parse(value, 'V2 observation: invalid token usage')
  ---@cast result OpencodeV2TokenUsage
  return result
end

---@param value OpencodeV2ModelReference|nil
---@return OpencodeV2NormalizedModel|nil
local function mapped_model(value)
  if value == nil then
    return nil
  end
  local result = model_shape:parse(value, 'V2 observation: invalid model reference')
  ---@cast result OpencodeV2NormalizedModel
  return result
end

local session_shape = v.object({
  id = 'string',
  projectID = 'string',
  location = { directory = 'string' },
  time = { created = 'number', updated = 'number' },
}):convert(function(info)
  return {
    id = info.id,
    parentID = info.parentID,
    projectID = info.projectID,
    agent = info.agent,
    model = mapped_model(info.model),
    cost = info.cost,
    tokens = mapped_tokens(info.tokens),
    outcome = info.outcome,
    time = {
      created = info.time.created,
      updated = info.time.updated,
      idle = info.time.idle,
      viewed = info.time.viewed,
      archived = info.time.archived,
    },
    title = info.title,
    location = vim.deepcopy(info.location),
    subpath = info.subpath,
    metadata = vim.deepcopy(info.metadata),
    permissions = vim.deepcopy(info.permissions),
    revert = vim.deepcopy(info.revert),
  }
end)

---@param value OpencodeV2ValidatedFileMention|nil
---@param text string
---@return OpencodeV2Mention|nil
local function mapped_mention(value, text)
  if value == nil then
    return nil
  end
  if not mention_shape:is(value) then
    log.warn('dropping malformed prompt mention: %s', vim.inspect(value))
    return nil
  end
  if not util.is_utf16_boundary(text, value.start) or not util.is_utf16_boundary(text, value['end']) then
    log.warn('dropping prompt mention outside UTF-16 boundaries: %s', vim.inspect(value))
    return nil
  end
  local start_byte = util.byte_index_from_utf16(text, value.start)
  local end_byte = util.byte_index_from_utf16(text, value['end'])
  if not start_byte or not end_byte then
    log.warn('dropping prompt mention with stale text range: %s', vim.inspect(value))
    return nil
  end
  ---@cast start_byte integer
  ---@cast end_byte integer
  if text:sub(start_byte + 1, end_byte) ~= value.text then
    -- Servers store the offsets captured at mention time; edits to the
    -- surrounding text leave them stale. A misplaced mention only loses its
    -- text anchor, so drop it instead of failing the whole message page.
    log.warn('dropping prompt mention with stale text range: %s', vim.inspect(value))
    return nil
  end
  ---@type OpencodeV2Mention
  local mention = { text = value.text, start_byte = start_byte, end_byte = end_byte }
  return mention
end

local function mapped_file(file, prompt_text)
  local parsed = file_shape:parse(file, 'V2 observation: invalid file attachment')
  ---@cast parsed OpencodeV2ValidatedFileAttachment
  file = parsed
  ---@type OpencodeV2NormalizedFileAttachment
  local result = {
    kind = 'file',
    uri = 'data:' .. file.mime .. ';base64,' .. file.data,
    media_type = file.mime,
    name = file.name,
    mention = mapped_mention(file.mention, prompt_text),
  }
  if file.source ~= nil then
    result.source = file.source
  end
  return result
end

local tool_result_shape = v.union(
  v.object({ type = v.literal('text'), text = 'string' }):convert(function(value)
    return { kind = 'text', text = value.text }
  end),
  v.object({ type = v.literal('file'), uri = 'string', mime = 'string' }):convert(function(value)
    return { kind = 'file', uri = value.uri, media_type = value.mime, name = value.name }
  end)
)

local tool_file_change_shape = v.object({
  file = v.optional('string'),
  relativePath = v.optional('string'),
  filePath = v.optional('string'),
  path = v.optional('string'),
  patch = v.optional('string'),
  diff = v.optional('string'),
}):convert(function(file)
  return {
    path = first(file, { 'file', 'relativePath', 'filePath', 'path' }),
    diff = first(file, { 'patch', 'diff' }),
  }
end)

local file_tool_input_shape = v.object({
  filePath = v.optional('string'),
  path = v.optional('string'),
  content = v.optional('string'),
}):convert(function(input)
  return {
    path = first(input, { 'filePath', 'path' }),
    content = input.content,
  }
end)

local skill_metadata_shape = v.object({ name = v.optional('string') })
local tool_metadata_shape = v.object({
  diff = v.optional('string'),
  files = v.optional(v.array(tool_file_change_shape)),
})

---@class OpencodeV2ToolChange
---@field path string
---@field diff string

---@alias OpencodeV2ToolMetadataApplier fun(result: table, metadata: table): nil

local tool_part_shape = v.object({
  id = 'string',
  name = 'string',
  state = v.object({ status = v.enum({ 'streaming', 'running', 'completed', 'error' }) }),
  time = v.object({ created = 'number' }),
})

local assistant_text_shape = v.object({ type = v.literal('text'), text = 'string' })
local assistant_reasoning_shape = v.object({
  type = v.literal('reasoning'),
  text = 'string',
  time = v.optional(v.object({
    created = v.optional('number'),
    completed = v.optional('number'),
  })),
})

local message_info_shape = v.object({ id = 'string', type = 'string' })
local user_message_shape = v.object({
  text = 'string',
  files = v.optional(v.array(v.any())),
  agents = v.optional(v.array(v.any())),
  skills = v.optional(v.array(v.any())),
})
local assistant_message_shape = v.object({ agent = 'string', content = v.array(v.any()) })
local retry_shape = v.object({ attempt = 'number', at = 'number' })
local skill_message_shape = v.object({ skill = 'string', name = 'string', text = 'string' })
local shell_message_shape = v.object({ shellID = 'string', command = 'string', status = 'string' })
local compaction_message_shape = v.object({ status = 'string', reason = 'string' })
local agent_switch_shape = v.object({ agent = 'string' })
local location_switch_shape = v.object({ location = v.table() })
local editor_context_file_shape = v.object({ name = 'string', data = 'string' })

---@param value table
---@return OpencodeV2NormalizedToolResult
local function mapped_tool_result(value)
  local result = tool_result_shape:parse(value, 'V2 observation: invalid tool result content')
  ---@cast result OpencodeV2NormalizedToolResult
  return result
end

---@param result table
---@param name string
---@param input any
local function apply_tool_input(result, name, input)
  if name ~= 'read' and name ~= 'edit' and name ~= 'write' then
    return
  end
  local parsed = file_tool_input_shape:parse(input, 'V2 observation: invalid file tool input')

  if parsed.path == nil then
    return
  end

  result.target = { path = parsed.path }
  if parsed.content ~= nil then
    result.target.content = parsed.content
  end
end

---@param result table
---@param metadata table
---@return nil
local function apply_skill_metadata(result, metadata)
  local parsed = skill_metadata_shape:parse(metadata, 'V2 observation: invalid skill metadata')
  if parsed.name == nil then
    return
  end
  result.input = result.input or {}
  if type(result.input.name) ~= 'string' then
    result.input.name = parsed.name
  end
end

--- A one-entry change list if both `path` and `diff` are valid, else empty.
---@param path string?
---@param diff string?
---@return OpencodeV2ToolChange[]
local function single_file_change(path, diff)
  if type(path) == 'string' and type(diff) == 'string' then
    return { { path = path, diff = diff } }
  end
  return {}
end

---@param result table
---@param metadata table
---@return nil
local function apply_edit_metadata(result, metadata)
  local parsed = tool_metadata_shape:parse(metadata, 'V2 observation: invalid tool metadata')
  local target_path = result.target and result.target.path

  local changes = single_file_change(target_path, parsed.diff)
  if #changes == 0 and parsed.files then
    -- `edit` tools only ever touch one file, so fall back to the metadata's
    -- own diff for that same target path.
    for _, file in ipairs(parsed.files) do
      vim.list_extend(changes, single_file_change(target_path, file.diff))
    end
  end
  if #changes > 0 then
    result.changes = changes
  end
end

---@param result table
---@param metadata table
---@return nil
local function apply_patch_metadata(result, metadata)
  local parsed = tool_metadata_shape:parse(metadata, 'V2 observation: invalid tool metadata')
  local changes = {}
  if parsed.files == nil then
    return
  end
  for _, file in ipairs(parsed.files) do
    vim.list_extend(changes, single_file_change(file.path, file.diff))
  end
  if #changes > 0 then
    result.changes = changes
  end
end

---@type table<string, OpencodeV2ToolMetadataApplier?>
local tool_metadata_appliers = {
  skill = apply_skill_metadata,
  edit = apply_edit_metadata,
  patch = apply_patch_metadata,
  apply_patch = apply_patch_metadata,
}

---@param result table
---@param name string
---@param metadata any
---@return nil
local function apply_tool_metadata(result, name, metadata)
  local applier = tool_metadata_appliers[name]
  if applier == nil or metadata == nil then
    return
  end
  v.expect(type(metadata) == 'table', 'V2 observation: invalid tool metadata')
  ---@cast metadata table
  applier(result, metadata)
end

local function mapped_tool(part)
  tool_part_shape:parse(part, 'V2 observation: invalid assistant tool content')
  local status = part.state.status
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
    v.string():parse(part.state.input, 'V2 observation: invalid streaming tool input')
    result.input_text = part.state.input
  else
    v.table():parse(part.state.input, 'V2 observation: invalid tool input')
    result.input = vim.deepcopy(part.state.input)
    apply_tool_input(result, part.name, result.input)
  end
  if status == 'completed' or status == 'error' then
    if status == 'completed' then
      v.array(v.any()):parse(part.state.content, 'V2 observation: completed tool is missing result content')
    end
    if part.state.content ~= nil then
      result.result = {}
      for _, item in ipairs(part.state.content) do
        result.result[#result.result + 1] = mapped_tool_result(item)
      end
    end
    result.error = mapped_error(part.state.error)
  end
  apply_tool_metadata(result, part.name, part.state.metadata)
  return result
end

-- Assistant content parts are mapped the same data-driven way message
-- kinds are below: dispatch on `type` instead of an if/elseif chain.
local assistant_content_mappers = {
  text = function(part)
    assistant_text_shape:parse(part, 'V2 observation: invalid assistant text content')
    return { kind = 'text', text = part.text }
  end,
  reasoning = function(part)
    assistant_reasoning_shape:parse(part, 'V2 observation: invalid assistant reasoning content')
    return {
      kind = 'reasoning',
      text = part.text,
      time = part.time and { created = part.time.created, completed = part.time.completed } or nil,
    }
  end,
  tool = mapped_tool,
}

local function mapped_assistant_content(part)
  shape(part, {}, 'invalid assistant content')
  local mapper = assistant_content_mappers[part.type]
  v.expect(mapper ~= nil, 'V2 observation: unknown assistant content type: ' .. tostring(part.type))
  return mapper(part)
end

local function base_entry(session_id, info)
  message_info_shape:parse(info, 'V2 observation: invalid message info')
  return {
    id = info.id,
    session_id = session_id,
    kind = info.type,
    time = mapped_time(info.time),
    content = {},
  }
end

local function mapped_idle(_, info)
  one_of(info.outcome, { 'succeeded', 'failed', 'interrupted' }, 'invalid idle message')
  return nil
end

local function append_user_file(entry, file, index, text)
  shape(file, {}, 'invalid file attachment')
  local context_name = type(file.name) == 'string' and file.name:match('^editor%-context:([%a_]+)') or nil
  if context_name == 'review_comment' then context_name = 'review-comment' end
  if not context_name then
    entry.content[#entry.content + 1] = mapped_file(file, text)
    return
  end

  -- Editor-context attachments are mapped to the same contract as V1 synthetic parts.
  editor_context_file_shape:parse(file, 'V2 observation: invalid editor context attachment')
  local context_entry, decode_err =
    shared_decode_editor_context(context_name, vim.base64.decode(file.data), file.name, true, file.ignored)
  v.expect(not decode_err, 'V2 observation: ' .. tostring(decode_err))
  v.expect(context_entry ~= nil, 'V2 observation: invalid ' .. tostring(context_name) .. ' editor context attachment')
  ---@cast context_entry table
  context_entry.id = file.name .. '#' .. index
  entry.content[#entry.content + 1] = context_entry
end

local function mapped_user(entry, info)
  user_message_shape:parse(info, 'V2 observation: invalid user message')
  entry.content[1] = { kind = 'text', text = info.text }

  local attachment_index = 0
  for _, file in ipairs(info.files or {}) do
    attachment_index = attachment_index + 1
    append_user_file(entry, file, attachment_index, info.text)
  end
  for _, agent in ipairs(info.agents or {}) do
    shape(agent, { name = 'string' }, 'invalid agent attachment')
    entry.content[#entry.content + 1] = {
      kind = 'agent',
      name = agent.name,
      mention = mapped_mention(agent.mention, info.text),
    }
  end
  for _, skill in ipairs(info.skills or {}) do
    shape(skill, { id = 'string', name = 'string' }, 'invalid skill attachment')
    entry.content[#entry.content + 1] = {
      kind = 'skill',
      skill_id = skill.id,
      name = skill.name,
      text = skill.text,
      mention = mapped_mention(skill.mention, info.text),
    }
  end
  return entry
end

local function mapped_assistant(entry, info)
  assistant_message_shape:parse(info, 'V2 observation: invalid assistant message')
  entry.agent = info.agent
  entry.model = mapped_model(info.model)
  entry.snapshot = vim.deepcopy(info.snapshot)
  entry.finish = info.finish
  entry.cost = info.cost
  entry.tokens = mapped_tokens(info.tokens)
  entry.error = mapped_error(info.error)
  if info.retry ~= nil then
    retry_shape:parse(info.retry, 'V2 observation: invalid assistant retry')
    entry.retry = {
      attempt = info.retry.attempt,
      scheduled_at = info.retry.at,
      error = mapped_error(info.retry.error),
    }
  end
  for _, part in ipairs(info.content) do
    entry.content[#entry.content + 1] = mapped_assistant_content(part)
  end
  return entry
end

local function mapped_text_message(entry, info)
  v.string():parse(info.text, 'V2 observation: invalid ' .. info.type .. ' message')
  entry.description = info.description
  entry.content[1] = { kind = 'text', text = info.text }
  return entry
end

local function mapped_skill_message(entry, info)
  skill_message_shape:parse(info, 'V2 observation: invalid skill message')
  entry.skill_id = info.skill
  entry.name = info.name
  entry.content[1] = { kind = 'text', text = info.text }
  return entry
end

local function mapped_shell(entry, info)
  shell_message_shape:parse(info, 'V2 observation: invalid shell message')
  entry.shell_id = info.shellID
  entry.command = info.command
  entry.state = info.status
  entry.exit = info.exit
  if info.output ~= nil then
    entry.content[1] =
      { kind = 'text', text = type(info.output) == 'string' and info.output or vim.inspect(info.output) }
  end
  return entry
end

local function mapped_compaction(entry, info)
  compaction_message_shape:parse(info, 'V2 observation: invalid compaction message')
  entry.state = info.status
  entry.reason = info.reason
  entry.summary = info.summary
  entry.recent = info.recent
  entry.model = mapped_model(info.model)
  entry.error = mapped_error(info.error)
  entry.cost = info.cost
  entry.tokens = mapped_tokens(info.tokens)
  return entry
end

local function mapped_agent_switch(entry, info)
  agent_switch_shape:parse(info, 'V2 observation: invalid agent-switched message')
  entry.agent = info.agent
  entry.previous = info.previous
  return entry
end

local function mapped_model_switch(entry, info)
  entry.model = mapped_model(info.model)
  entry.previous = mapped_model(info.previous)
  return entry
end

local function mapped_location_switch(entry, info)
  location_switch_shape:parse(info, 'V2 observation: invalid location-switched message')
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
  return entry
end

local message_mappers = {
  idle = mapped_idle,
  user = mapped_user,
  assistant = mapped_assistant,
  synthetic = mapped_text_message,
  system = mapped_text_message,
  skill = mapped_skill_message,
  shell = mapped_shell,
  compaction = mapped_compaction,
  ['agent-switched'] = mapped_agent_switch,
  ['model-switched'] = mapped_model_switch,
  ['location-switched'] = mapped_location_switch,
}

---@param session_id string
---@param info table
---@return table|nil
local function mapped_message(session_id, info)
  local entry = base_entry(session_id, info)
  local mapper = message_mappers[info.type]
  v.expect(mapper ~= nil, 'V2 observation: unknown message type: ' .. tostring(info.type))
  return mapper(entry, info)
end

---@param info table
---@return OpencodeV2Session
local function mapped_session(info)
  local result = session_shape:parse(info, 'V2 observation: invalid session info')
  ---@cast result OpencodeV2Session
  return result
end

---@param item table
---@param status? string
---@return OpencodeV2InboxItem
local function mapped_inbox(item, status)
  local result = inbox_shape(status):parse(item, 'V2 observation: invalid inbox item')
  ---@cast result OpencodeV2InboxItem
  return result
end

---@param request table
---@return OpencodeV2PermissionRequest
local function mapped_permission(request)
  local result = permission_shape:parse(request, 'V2 observation: invalid permission request')
  ---@cast result OpencodeV2PermissionRequest
  return result
end

---@param form table
---@return OpencodeV2QuestionRequest
local function mapped_question(form)
  local result = question_shape:parse(form, 'V2 observation: invalid form request')
  ---@cast result OpencodeV2QuestionRequest
  return result
end

return {
  mapped_error = mapped_error,
  mapped_tokens = mapped_tokens,
  mapped_model = mapped_model,
  mapped_tool_result = mapped_tool_result,
  apply_tool_input = apply_tool_input,
  apply_tool_metadata = apply_tool_metadata,
  mapped_message = mapped_message,
  mapped_session = mapped_session,
  mapped_inbox = mapped_inbox,
  mapped_permission = mapped_permission,
  mapped_question = mapped_question,
}
