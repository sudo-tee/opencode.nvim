local submission = require('opencode.protocols.submission')
local facts = require('opencode.protocols.v2.facts')
local mapped_error = facts.mapped_error
local mapped_tokens = facts.mapped_tokens
local mapped_model = facts.mapped_model
local mapped_tool_result = facts.mapped_tool_result
local mapped_message = facts.mapped_message
local session_fact = facts.session_fact
local inbox_fact = facts.inbox_fact
local permission_fact = facts.permission_fact
local question_fact = facts.question_fact

local lifecycle = require('opencode.protocols.observation')
local Promise = require('opencode.promise')

local M = {}

local function fail(message)
  error('V2 observation: ' .. message, 0)
end

local function record_diagnostic(observation, resource, message)
  observation:read().sync[resource] = lifecycle.sync_error('protocol_contract', message)
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
    local entry = mapped_message(observation._session_id, messages[index])
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
    local ok, entry = pcall(mapped_message, observation._session_id, info)
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

local function mark_admissions_unknown(observation, reason)
  observation._v2_delivered = {}
  local pending = vim.tbl_values(observation._v2_admissions)
  for _, admission in ipairs(pending) do
    admission.finish(nil, 'V2 observation: admission_unknown: ' .. tostring(reason))
  end
end

local function complete_admission(admission, terminal)
  if terminal.ambiguous then
    admission.finish(nil, 'V2 observation: admission_unknown: multiple inputs delivered in one execution')
    return
  end
  admission.finish({
    kind = 'session_idle',
    outcome = terminal.outcome,
    idle_at = terminal.idle_at,
    error = terminal.error,
  })
end

local function remove_from_order(order, id)
  for index, value in ipairs(order) do
    if value == id then
      table.remove(order, index)
      return
    end
  end
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

local function settle_admissions(observation, terminal)
  local deliveries = 0
  for _, delivery in pairs(observation._v2_delivered) do
    if not delivery.terminal then
      delivery.terminal = terminal
      deliveries = deliveries + 1
    end
  end
  terminal.ambiguous = deliveries > 1
  local pending = vim.tbl_values(observation._v2_admissions)
  for _, admission in ipairs(pending) do
    if admission.delivery and admission.delivery.terminal == terminal then
      complete_admission(admission, terminal)
    end
  end
end

local function execution_event(observation, event)
  local data = event_identity(observation, event, 'execution')
  if data == nil or data == false then
    return false
  end
  local state = observation:read()
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
      outcome = outcome,
      idle_at = event.created,
      error = event.type == 'session.execution.failed' and mapped_error(data.error) or nil,
    }
    state.execution = { activity = 'idle', last_outcome = outcome, last_idle = event.created }
    settle_admissions(observation, terminal)
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
      local delivery = observation._v2_delivered[data.inboxID] or {}
      observation._v2_delivered[data.inboxID] = delivery
      local admission = observation._v2_admissions[data.inboxID]
      if admission then
        admission.delivery = delivery
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
  if event.type ~= 'filesystem.changed' and event.type ~= 'file.edited' then
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

local function find_reply(observation, input_id)
  local state = observation:read()
  local input_found, reply = false, nil
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
    find_reply = find_reply,
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
  observation._v2_terminal_seen_since_start = false
  observation._v2_horizon_ambiguous = false
  observation._v2_execution_event_active = false
  observation._v2_older_cursor = nil
  observation._v2_history_complete = false
  observation._v2_older_loading = false

  ---@param input table
  ---@return Promise<OpencodeSubmission>
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
      if self._v2_admissions[admission.id] then
        fail('duplicate submit admission')
      end
      local release = self:_begin_local_operation()
      local record = { delivery = self._v2_delivered[admission.id] }
      local handle, complete = submission.new({ kind = 'accepted', input = vim.deepcopy(admission) }, function()
        if self._v2_admissions[admission.id] == record then
          self._v2_admissions[admission.id] = nil
        end
        release()
      end)
      record.finish = complete
      self._v2_admissions[admission.id] = record
      if self._v2_stream_generation ~= stream_generation then
        complete(nil, 'V2 observation: admission_unknown: event stream continuity was lost during submit')
      elseif self._v2_horizon_ambiguous then
        complete(nil, 'V2 observation: admission_unknown: overlapping execution horizons')
      elseif record.delivery and record.delivery.terminal then
        complete_admission(record, record.delivery.terminal)
      end
      return handle
    end)
    return result:finally(finish)
  end

  ---True when the server still has message pages older than the cached
  ---window (v2 pages backwards through `cursor.next`).
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
      if self._v2_history_complete or not self._v2_older_cursor then
        return resolved(nil)
      end
      return self:load_older():and_then(pull)
    end
    return pull()
  end

  function observation:interrupt()
    return self:_start_action(connection.operations.interrupt, self._session_id)
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
    return self:_start_action(connection.operations.reply_permission, self._session_id, request_id, {
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
    return self:_start_action(connection.operations.reply_question, self._session_id, request_id, answers)
  end

  function observation:reject_question(request_id)
    local request = self:read().question_requests_by_id[request_id]
    if not request or request.status ~= 'pending' then
      fail('question request is not pending')
    end
    return self:_start_action(connection.operations.cancel_question, self._session_id, request_id)
  end
  return observation
end

---@param connection table
function M.close(connection)
  lifecycle.close(connection)
end

return M
