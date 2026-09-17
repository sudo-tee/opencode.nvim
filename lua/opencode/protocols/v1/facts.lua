local util = require('opencode.util')

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
  return type(value) == 'table'
    and type(value.value) == 'string'
    and type(value.start) == 'number'
    and type(value['end']) == 'number'
    and value.start % 1 == 0
    and value['end'] % 1 == 0
    and value.start >= 0
    and value['end'] >= value.start
end

---@param value any
---@param prompt? string
---@return table|nil
---@return string|nil diagnostic
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

---@param part table
---@param prompt? string
---@param location? table
---@return table
---@return string|nil diagnostic
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

---@param info table
---@param content table[]
---@return table
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

---@param message table
---@param location? table
---@return table
---@return string[] diagnostics
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

---@param info table
---@return table
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

---@param request table
---@return table
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

---@param request table
---@return table
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
  session_fact = session_fact,
  permission_fact = permission_fact,
  question_fact = question_fact,
}
