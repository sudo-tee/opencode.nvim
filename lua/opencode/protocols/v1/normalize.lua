local util = require('opencode.util')
local v = require('opencode.shape')
local shared_decode_editor_context = require('opencode.protocols.observation').decode_editor_context

local function fail(message)
  error('V1 observation: ' .. message, 0)
end

local error_shape = v.union(
  v.string():convert(function(value)
    return { message = value }
  end),
  v.table():convert(function(value)
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
  end)
)

local time_shape = v.table():convert(vim.deepcopy)
local content_time_shape = v.object({ start = 'number' }):convert(function(value)
  return { started = value.start, completed = value['end'] }
end)

local part_shape = v.object({
  id = 'string',
  sessionID = 'string',
  messageID = 'string',
  type = 'string',
})

local tool_part_shape = v.object({
  callID = 'string',
  tool = 'string',
  state = v.object({ status = v.enum({ 'pending', 'running', 'completed', 'error' }) }),
})

local message_info_shape = v.object({
  id = 'string',
  sessionID = 'string',
  role = v.enum({ 'user', 'assistant' }),
  time = v.object({ created = 'number' }),
})

local message_shape = v.object({
  info = v.table(),
  parts = v.array(v.any()),
})

local native_mention_shape = v.object({
  value = 'string',
  start = v.integer():min(0),
  ['end'] = v.integer():min(0),
}):constraint(function(value)
  return value['end'] >= value.start
end, 'valid native mention')

local file_source_shape = v.union(
  v.object({ type = v.literal('file'), path = 'string' }):convert(function(value)
    return { kind = 'file', path = value.path }
  end),
  v.object({ type = v.literal('symbol'), path = 'string', name = 'string', range = 'table' }):convert(function(value)
    return { kind = 'symbol', path = value.path, name = value.name, range = vim.deepcopy(value.range) }
  end),
  v.object({ type = v.literal('resource'), uri = 'string' }):convert(function(value)
    return { kind = 'resource', uri = value.uri }
  end)
)

local function mapped_session_info(info)
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
    time = time_shape:parse(info.time),
    summary = vim.deepcopy(info.summary),
    share = vim.deepcopy(info.share),
    revert = vim.deepcopy(info.revert),
  }
end

local session_shape = v.object({
  id = 'string',
  slug = 'string',
  projectID = 'string',
  directory = 'string',
  title = 'string',
  version = 'string',
  time = { created = 'number', updated = 'number' },
}):convert(mapped_session_info)

local legacy_revert_shape = v.object({
  messageID = 'string',
  partID = v.string():optional(),
  snapshot = v.string():optional(),
  diff = v.string():optional(),
})

local legacy_revert_session_shape = v.object({
  id = 'string',
  projectID = 'string',
  directory = 'string',
  title = 'string',
  version = v.string():constraint(function(version)
    return version:match('^0%.%d+%.%d+') ~= nil
  end, 'legacy V1 version'),
  time = { created = 'number', updated = 'number' },
  revert = legacy_revert_shape,
})
  :constraint(function(info)
    return info.slug == nil
  end, 'legacy V1 session without slug')
  :convert(mapped_session_info)

local permission_metadata_shape = v.object({
  command = v.string():optional(),
  diff = v.string():optional(),
  filePath = v.string():optional(),
  filepath = v.string():optional(),
})

local permission_shape = v.object({
  id = 'string',
  sessionID = 'string',
  permission = 'string',
  patterns = v.array('string'),
  metadata = v.table(),
  always = v.array('string'),
}):convert(function(request)
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
end)

local legacy_permission_shape = v.object({
  id = 'string',
  sessionID = 'string',
  type = 'string',
  title = 'string',
  messageID = 'string',
  callID = 'string',
  time = v.object({ created = 'number' }),
  pattern = v.union(v.string(), v.array('string')):optional(),
  metadata = permission_metadata_shape,
}):convert(function(request)
  local patterns = request.pattern or {}
  if type(patterns) == 'string' then
    patterns = { patterns }
  end
  local mapped = permission_shape:parse({
    id = request.id,
    sessionID = request.sessionID,
    permission = request.type,
    patterns = patterns,
    always = {},
    metadata = request.metadata,
    tool = { messageID = request.messageID, callID = request.callID },
  })
  mapped.preview = {
    title = request.title,
    command = request.metadata.command,
    diff = request.metadata.diff,
    path = request.metadata.filePath or request.metadata.filepath,
    source = { message_id = request.messageID, call_id = request.callID },
  }
  return mapped
end)

local permission_reply_shape = v.union(
  v.object({ sessionID = 'string', requestID = 'string', reply = v.enum({ 'once', 'always', 'reject' }) })
    :convert(function(reply)
      return { session_id = reply.sessionID, request_id = reply.requestID, reply = reply.reply }
    end),
  v.object({ sessionID = 'string', permissionID = 'string', response = v.enum({ 'once', 'always', 'reject' }) })
    :convert(function(reply)
      return { session_id = reply.sessionID, request_id = reply.permissionID, reply = reply.response }
    end)
)

local question_shape = v.object({
  id = 'string',
  sessionID = 'string',
  questions = v.array(v.object({
    question = 'string',
    header = 'string',
    options = v.array(v.object({ label = 'string', description = 'string' })),
  })),
}):convert(function(request)
  local fields = {}
  for index, question in ipairs(request.questions) do
    local options = {}
    for _, option in ipairs(question.options) do
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
end)

local function mapped_error(value)
  if value == nil then
    return nil
  end
  return error_shape:parse(value, 'V1 observation: invalid error')
end

local function mapped_time(value)
  if value == nil then
    return nil
  end
  return time_shape:parse(value, 'V1 observation: invalid time')
end

local function mapped_content_time(value)
  if value == nil then
    return nil
  end
  return content_time_shape:parse(value, 'V1 observation: invalid content time')
end

local legacy_synthetic_context_shape = v.object({ synthetic = v.literal(true), text = 'string' })
local legacy_context_marker_shape = v.object({
  context_type = v.enum({ 'selection', 'diagnostics', 'cursor-data', 'review-comment' }),
})
local legacy_diagnostics_shape = v.object({
  context_type = v.literal('diagnostics'),
  content = v.array(v.union(
    v.object({ msg = 'string', severity = v.enum({ 1, 2, 3, 4 }), pos = 'string' }),
    v.object({
      message = 'string',
      severity = v.enum({ 1, 2, 3, 4 }),
      lnum = v.integer():min(0),
      col = v.integer():min(0),
    }):convert(function(value)
      return {
        msg = value.message,
        severity = value.severity,
        pos = string.format('l%d:c%d', value.lnum + 1, value.col + 1),
      }
    end)
  )),
})

local function legacy_context_content(part)
  if not legacy_synthetic_context_shape:is(part) then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, part.text)
  if not ok or not legacy_context_marker_shape:is(decoded) then
    return nil
  end
  local text = part.text
  if decoded.context_type == 'diagnostics' then
    if not legacy_diagnostics_shape:is(decoded) then
      return nil, 'invalid diagnostics editor context'
    end
    -- Historical captures stored raw Neovim diagnostics with zero-based positions.
    text = vim.json.encode(legacy_diagnostics_shape:parse(decoded))
  end
  return shared_decode_editor_context(decoded.context_type, text, part.id, part.synthetic, part.ignored)
end

local function context_content(part)
  local metadata = part.metadata
  local context_type = type(metadata) == 'table' and metadata.context_type or nil
  if context_type == nil then
    return legacy_context_content(part)
  end
  if context_type == 'file-content' and type(metadata.mime) == 'string' then
    -- V1 carries the buffer media type in part metadata
    local entry, err = shared_decode_editor_context(context_type, part.text, part.id, part.synthetic, part.ignored)
    if not entry then
      return entry, err
    end
    entry.source.media_type = metadata.mime
    return entry
  end
  return shared_decode_editor_context(context_type, part.text, part.id, part.synthetic, part.ignored)
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

---@param content table[]
---@return string|nil
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

---@param value any
---@return boolean
local function valid_native_mention(value)
  return native_mention_shape:is(value)
end

---@param value any
---@param prompt? string
---@return table|nil
---@return string|nil diagnostic
---@return boolean? waiting
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
  if not start_byte or not end_byte then
    return nil, 'native mention does not identify a prompt range'
  end
  ---@cast start_byte integer
  ---@cast end_byte integer
  if prompt:sub(start_byte + 1, end_byte) ~= value.value then
    return nil, 'native mention does not identify a prompt range'
  end
  return { text = value.value, start_byte = start_byte, end_byte = end_byte }
end

local function mapped_file_source(value, prompt)
  if value == nil then
    return nil, nil
  end
  local source = file_source_shape:parse(value, 'V1 observation: invalid file source')
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
      local valid = true
      for index, file in ipairs(metadata.files) do
        local path = type(file) == 'table' and (file.relativePath or file.filePath) or nil
        if type(path) ~= 'string' then
          diagnostics[#diagnostics + 1] = diagnostic_prefix .. 'file ' .. index .. ' has no path'
          valid = false
          break
        end
        changes[#changes + 1] = {
          path = path,
          location = vim.deepcopy(location),
          diff = type(file.diff) == 'string' and file.diff or type(file.patch) == 'string' and file.patch or nil,
        }
      end
      fields.changes = valid and changes or nil
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
      ---@type table[]?
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
      local valid = true
      local states = { pending = true, in_progress = true, completed = true }
      for index, todo in ipairs(input.todos) do
        if type(todo) ~= 'table' or type(todo.content) ~= 'string' or not states[todo.status] then
          diagnostics[#diagnostics + 1] = diagnostic_prefix .. 'todo ' .. index .. ' is invalid'
          valid = false
          break
        end
        todos[#todos + 1] = { text = todo.content, state = todo.status }
      end
      fields.todos = valid and todos or nil
    end
  end

  return fields, diagnostics
end

local function tool_content(part, prompt, location)
  tool_part_shape:parse(part, 'V1 observation: invalid tool state for part ' .. part.id)
  local state = part.state
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
  if type(state.metadata) == 'table' and type(state.metadata.interrupted) == 'boolean' then
    content.interrupted = state.metadata.interrupted
  end
  local specialized, specialized_diagnostics = tool_specialized_fields(part, location)
  for key, value in pairs(specialized) do
    content[key] = value
  end
  vim.list_extend(diagnostics, specialized_diagnostics)
  return content, #diagnostics > 0 and table.concat(diagnostics, '; ') or nil
end

local content_mappers = {
  text = function(part)
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
  end,
  reasoning = function(part)
    return { id = part.id, kind = 'reasoning', text = part.text, time = mapped_content_time(part.time) }
  end,
  file = function(part, prompt)
    return file_content(part, prompt)
  end,
  agent = function(part, prompt)
    local mention, diagnostic, waiting = mapped_mention(part.source, prompt)
    return {
      id = part.id,
      kind = 'agent',
      name = part.name,
      mention = mention,
    },
      diagnostic,
      waiting
  end,
  tool = function(part, prompt, location)
    return tool_content(part, prompt, location)
  end,
  compaction = function(part)
    return {
      id = part.id,
      kind = 'compaction',
      auto = part.auto,
      overflow = part.overflow,
      boundary = part.tail_start_id,
    }
  end,
  subtask = function(part)
    return {
      id = part.id,
      kind = 'subtask',
      prompt = part.prompt,
      description = part.description,
      agent = part.agent,
      model = vim.deepcopy(part.model),
      command = part.command,
    }
  end,
  retry = function(part)
    return {
      id = part.id,
      kind = 'retry',
      attempt = part.attempt,
      error = mapped_error(part.error),
      time = mapped_time(part.time),
    }
  end,
  snapshot = function(part)
    return { id = part.id, kind = 'snapshot', snapshot = part.snapshot }
  end,
  patch = function(part)
    return { id = part.id, kind = 'patch', hash = part.hash, files = vim.deepcopy(part.files) }
  end,
  ['step-start'] = function(part)
    return { id = part.id, kind = 'step_start', snapshot = part.snapshot }
  end,
  ['step-finish'] = function(part)
    return {
      id = part.id,
      kind = 'step_finish',
      reason = part.reason,
      snapshot = part.snapshot,
      cost = part.cost,
      tokens = vim.deepcopy(part.tokens),
    }
  end,
}

---@param part table
---@param prompt? string
---@param location? table
---@return table
---@return string|nil diagnostic
---@return boolean? waiting
local function mapped_content(part, prompt, location)
  part_shape:parse(part, 'V1 observation: invalid part identity')
  local mapper = content_mappers[part.type]
  v.expect(mapper ~= nil, 'V1 observation: unsupported part type: ' .. part.type)
  ---@cast mapper function
  return mapper(part, prompt, location)
end

---@param info table
---@param content table[]
---@return table
local function entry_from_info(info, content)
  message_info_shape:parse(info, 'V1 observation: invalid message info')
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

---@param message table
---@param location? table
---@return table
---@return string[] diagnostics
local function mapped_message(message, location)
  message_shape:parse(message, 'V1 observation: invalid WithParts response')
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

---@param info table
---@return table session
---@return boolean legacy_revert
local function mapped_session(info)
  local current_ok, session = pcall(session_shape.parse, session_shape, info)
  if current_ok then
    ---@cast session table
    return session, false
  end
  return legacy_revert_session_shape:parse(info, 'V1 observation: invalid session info'), true
end

---@param request table
---@return table
local function mapped_permission(request)
  if request.permission == nil and request.type ~= nil then
    return legacy_permission_shape:parse(request, 'V1 observation: invalid legacy permission request')
  end
  return permission_shape:parse(request, 'V1 observation: invalid permission request')
end

---Only validated, linked tool input can enrich the frozen permission preview.
---@param state OpencodeObservationState
---@return boolean
local function enrich_permission_previews(state)
  local changed = false
  for _, request in pairs(state.permission_requests_by_id) do
    local preview = request.preview
    local source = preview and preview.source
    local entry = source and state.entries_by_id[source.message_id]
    if request.status == 'pending' and preview and source and entry then
      for _, content in ipairs(entry.content) do
        ---@cast content {kind: string, call_id?: string, description?: string, command?: string}
        if content.kind == 'tool' and content.call_id == source.call_id then
          if content.description and content.description ~= '' and request.message ~= content.description then
            request.message = content.description
            changed = true
          end
          if content.command and content.command ~= '' and preview.command ~= content.command then
            preview.command = content.command
            changed = true
          end
        end
      end
    end
  end
  return changed
end

---@param request table
---@return table
local function mapped_question(request)
  return question_shape:parse(request, 'V1 observation: invalid question request')
end

---@param entry table
---@return boolean
local function is_terminal_reply(entry)
  if entry.kind ~= 'assistant' or type(entry.time) ~= 'table' or type(entry.time.completed) ~= 'number' then
    return false
  end
  if entry.error ~= nil then
    return true
  end
  if
    type(entry.finish) ~= 'string'
    or entry.finish == ''
    or entry.finish == 'tool-calls'
    or entry.finish == 'unknown'
  then
    return false
  end
  for _, content in ipairs(entry.content) do
    if content.kind == 'tool' and not content.executed and not (content.state == 'error' and content.interrupted) then
      return false
    end
  end
  return true
end

return {
  is_terminal_reply = is_terminal_reply,
  prompt_from_content = prompt_from_content,
  valid_native_mention = valid_native_mention,
  mapped_mention = mapped_mention,
  mapped_content = mapped_content,
  entry_from_info = entry_from_info,
  mapped_message = mapped_message,
  mapped_session = mapped_session,
  mapped_permission = mapped_permission,
  mapped_legacy_permission = function(request)
    return legacy_permission_shape:parse(request, 'V1 observation: invalid legacy permission request')
  end,
  mapped_current_permission = function(request)
    return permission_shape:parse(request, 'V1 observation: invalid permission request')
  end,
  mapped_permission_reply = function(reply)
    return permission_reply_shape:parse(reply, 'permission.replied is missing request identity or has invalid reply')
  end,
  enrich_permission_previews = enrich_permission_previews,
  mapped_question = mapped_question,
}
