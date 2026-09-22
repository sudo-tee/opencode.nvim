local normalize = require('opencode.protocols.v2.normalize')
local lifecycle = require('opencode.protocols.observation')
local boundary = require('opencode.protocols.v2.observation.boundary')
local messages = require('opencode.protocols.v2.observation.messages')
local actions = require('opencode.protocols.v2.observation.actions')

local M = {}

---@param order string[]
---@param id string
local function remove_from_order(order, id)
  for index, value in ipairs(order) do
    if value == id then
      table.remove(order, index)
      return
    end
  end
end

---@param children OpencodeV2Children
---@param child table
local function put_child(children, child)
  local existed = children.by_id[child.id] ~= nil
  children.by_id[child.id] = child
  if not existed then
    children.order[#children.order + 1] = child.id
  end
end

---@param observation OpencodeV2Observation
---@param id string
---@param status 'delivered'|'cancelled'
---@param created number
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

---@type table<string, OpencodeV2EventHandler>
local execution_handlers = {}

---@param observation OpencodeV2Observation
execution_handlers['session.execution.started'] = function(observation)
  local state = observation:read()
  if observation._v2_execution_event_active then
    state.execution = {
      activity = 'unknown',
      error = { kind = 'ambiguous_execution', message = 'overlapping V2 execution horizons' },
    }
    actions.execution_ambiguous(observation)
    return
  end
  state.execution = { activity = 'running' }
  observation._v2_execution_event_active = true
  observation._v2_terminal_seen_since_start = false
end

---@param observation OpencodeV2Observation
---@param data table
execution_handlers['session.retry.scheduled'] = function(observation, _, data)
  if type(data.attempt) ~= 'number' or type(data.at) ~= 'number' then
    return boundary.diagnostic(observation, 'execution', 'session.retry.scheduled is missing attempt/at')
  end
  local err = normalize.mapped_error(data.error)
  local message = err and type(err.message) == 'string' and err.message ~= '' and err.message
    or (type(data.message) == 'string' and data.message ~= '' and data.message or nil)
  observation:read().execution = {
    activity = 'retrying',
    retry = { attempt = data.attempt, message = message, scheduled_at = data.at, error = err },
  }
  observation._v2_execution_event_active = true
end

---@param observation OpencodeV2Observation
---@param event OpencodeV2Event
---@param data table
---@return false|nil
local function finish_execution(observation, event, data)
  if observation._v2_terminal_seen_since_start then
    return false
  end
  observation._v2_terminal_seen_since_start = true
  observation._v2_execution_event_active = false
  local outcome = event.type:match('%.([^.]+)$')
  ---@cast outcome OpencodeV2Outcome
  local terminal = {
    outcome = outcome,
    idle_at = event.created,
    error = event.type == 'session.execution.failed' and normalize.mapped_error(data.error) or nil,
  }
  observation:read().execution = { activity = 'idle', last_outcome = outcome, last_idle = event.created }
  actions.execution_finished(observation, terminal)
end
execution_handlers['session.execution.succeeded'] = finish_execution
execution_handlers['session.execution.failed'] = finish_execution
execution_handlers['session.execution.interrupted'] = finish_execution

---@type table<string, OpencodeV2EventHandler>
local inbox_handlers = {}

---@param observation OpencodeV2Observation
---@param event OpencodeV2Event
---@param data table
inbox_handlers['session.inbox.enqueued'] = function(observation, event, data)
  if type(data.item) ~= 'table' then
    return boundary.diagnostic(observation, 'inbox', 'session.inbox.enqueued is missing item')
  end
  local native = vim.deepcopy(data.item)
  native.id, native.sessionID, native.timeCreated = data.inboxID, observation._session_id, event.created
  local item = normalize.mapped_inbox(native)
  local terminal = observation._v2_inbox_terminal[item.id]
  if terminal then
    item.status = terminal.status
  end
  local state = observation:read()
  if not state.inbox.items_by_id[item.id] then
    state.inbox.order[#state.inbox.order + 1] = item.id
  end
  state.inbox.items_by_id[item.id] = item
end

---@param status 'delivered'|'cancelled'
---@return OpencodeV2EventHandler
local function finish_inbox(status)
  ---@param observation OpencodeV2Observation
  ---@param event OpencodeV2Event
  ---@param data table
  return function(observation, event, data)
    terminal_inbox(observation, data.inboxID, status, event.created)
    if status == 'delivered' then
      actions.delivered(observation, data.inboxID)
    end
  end
end
inbox_handlers['session.inbox.delivered'] = finish_inbox('delivered')
inbox_handlers['session.inbox.cancelled'] = finish_inbox('cancelled')

---@param observation OpencodeV2Observation
---@param _ OpencodeV2Event
---@param data table
inbox_handlers['session.inbox.delivery.changed'] = function(observation, _, data)
  local item = observation:read().inbox.items_by_id[data.inboxID]
  if not item or (data.delivery ~= 'steer' and data.delivery ~= 'queue') then
    return boundary.diagnostic(observation, 'inbox', 'session.inbox.delivery.changed cannot identify a pending item')
  end
  item.delivery = data.delivery
end

---@type table<string, OpencodeV2EventHandler>
local permission_handlers = {}

---@param observation OpencodeV2Observation
---@param _ OpencodeV2Event
---@param data table
permission_handlers['permission.asked'] = function(observation, _, data)
  local request = normalize.mapped_permission(data)
  local terminal = observation._v2_permission_terminal[request.id]
  if terminal then
    request.status, request.answer = 'answered', terminal.answer
  end
  observation:read().permission_requests_by_id[request.id] = request
end

---@param observation OpencodeV2Observation
---@param _ OpencodeV2Event
---@param data table
permission_handlers['permission.replied'] = function(observation, _, data)
  if type(data.requestID) ~= 'string' then
    return boundary.diagnostic(observation, 'permissions', 'permission.replied is missing requestID')
  end
  observation._v2_permission_terminal[data.requestID] = { answer = data.reply }
  local request = observation:read().permission_requests_by_id[data.requestID]
  if request then
    request.status, request.answer = 'answered', data.reply
  end
end

---@type table<string, OpencodeV2EventHandler>
local question_handlers = {}

---@param observation OpencodeV2Observation
---@param _ OpencodeV2Event
---@param data table
question_handlers['form.created'] = function(observation, _, data)
  local form = normalize.mapped_question(data)
  local terminal = observation._v2_question_terminal[form.id]
  if terminal then
    form.status = terminal.status
    form.answers = terminal.answers and vim.deepcopy(terminal.answers) or nil
  end
  observation:read().question_requests_by_id[form.id] = form
end

---@param status 'answered'|'cancelled'
---@return OpencodeV2EventHandler
local function finish_question(status)
  ---@param observation OpencodeV2Observation
  ---@param event OpencodeV2Event
  ---@param data table
  return function(observation, event, data)
    if type(data.id) ~= 'string' then
      return boundary.diagnostic(observation, 'questions', event.type .. ' is missing form id')
    end
    local terminal = {
      status = status,
      answers = status == 'answered' and vim.deepcopy(data.answer) or nil,
    }
    observation._v2_question_terminal[data.id] = terminal
    local form = observation:read().question_requests_by_id[data.id]
    if form then
      form.status, form.answers = terminal.status, terminal.answers
    end
  end
end
question_handlers['form.replied'] = finish_question('answered')
question_handlers['form.cancelled'] = finish_question('cancelled')

---@type table<string, OpencodeV2EventHandler>
local session_handlers = {}

---@param observation OpencodeV2Observation
---@param event OpencodeV2Event
---@param data table
session_handlers['session.created'] = function(observation, event, data)
  local info = vim.deepcopy(data)
  info.id = data.sessionID
  info.time = { created = event.created, updated = event.created }
  observation:read().session = normalize.mapped_session(info)
end

---@param observation OpencodeV2Observation
---@param _ OpencodeV2Event
---@param data table
session_handlers['session.renamed'] = function(observation, _, data)
  if type(data.title) ~= 'string' then
    return boundary.diagnostic(observation, 'session', 'session.renamed is missing title')
  end
  observation:read().session.title = data.title
end

---@param observation OpencodeV2Observation
---@param _ OpencodeV2Event
---@param data table
session_handlers['session.moved'] = function(observation, _, data)
  if type(data.location) ~= 'table' then
    return boundary.diagnostic(observation, 'session', 'session.moved is missing location')
  end
  local session = observation:read().session
  session.location = vim.deepcopy(data.location)
  session.projectID, session.subpath = data.projectID, data.subpath
end

---@param observation OpencodeV2Observation
---@param _ OpencodeV2Event
---@param data table
session_handlers['session.usage.updated'] = function(observation, _, data)
  if type(data.cost) ~= 'number' then
    return boundary.diagnostic(observation, 'session', 'session.usage.updated has invalid cost')
  end
  local ok, tokens = pcall(normalize.mapped_tokens, data.tokens)
  if not ok then
    return boundary.diagnostic(observation, 'session', tostring(tokens))
  end
  observation:read().session.cost = data.cost
  observation:read().session.tokens = tokens
end

---@param observation OpencodeV2Observation
session_handlers['session.deleted'] = function(observation)
  observation:read().sync.session = lifecycle.sync_error('session_deleted', 'session was deleted')
  return 'terminal'
end

---@param observation OpencodeV2Observation
---@param event OpencodeV2Event
---@return boolean
local function children_event(observation, event)
  local data = type(event.data) == 'table' and event.data
  if event.type == 'session.created' and data and data.parentID == observation._session_id then
    local info = vim.deepcopy(data)
    info.id = info.sessionID
    info.time = { created = event.created, updated = event.created }
    put_child(observation:read().children, normalize.mapped_session(info))
  elseif event.type == 'session.deleted' and data and type(data.sessionID) == 'string' then
    local children = observation:read().children
    if not children.by_id[data.sessionID] then
      return false
    end
    children.by_id[data.sessionID] = nil
    remove_from_order(children.order, data.sessionID)
  else
    return false
  end
  observation:read().sync.children = { state = 'current' }
  return true
end

local file_events = { ['filesystem.changed'] = true, ['file.edited'] = true }

---@param observation OpencodeV2Observation
---@param event OpencodeV2Event
---@return boolean
local function file_event(observation, event)
  if not file_events[event.type] then
    return false
  end
  local data = event.data
  if type(data) ~= 'table' or type(data.file) ~= 'string' then
    boundary.diagnostic(observation, 'files', event.type .. ' is missing file')
    return true
  end
  if data.event ~= nil and type(data.event) ~= 'string' then
    boundary.diagnostic(observation, 'files', event.type .. ' has invalid event')
    return true
  end
  local files = observation:read().files
  files.revision = files.revision + 1
  files.last = { path = data.file, event = data.event or 'change' }
  observation:read().sync.files = { state = 'current' }
  return true
end

---@type table<string, OpencodeV2Route|nil>
local routes = {}
for resource, handlers in pairs({
  inbox = inbox_handlers,
  execution = execution_handlers,
  permissions = permission_handlers,
  questions = question_handlers,
  session = session_handlers,
}) do
  for event_type, handler in pairs(handlers) do
    routes[event_type] = { resource = resource, apply = handler }
  end
end

---@param observation OpencodeV2Observation
---@param event OpencodeV2Event
---@param route OpencodeV2Route
---@return boolean
local function apply_event(observation, event, route)
  local resource = route.resource
  local data = event.data
  if event.type == 'form.created' then
    local form = data.form
    if type(form) ~= 'table' then
      return boundary.diagnostic(observation, resource, 'form.created is missing form')
    end
    data = form
    if data.sessionID ~= observation._session_id then
      return false
    end
  end
  if resource == 'inbox' and type(data.inboxID) ~= 'string' then
    return boundary.diagnostic(observation, resource, event.type .. ' is missing inboxID')
  end
  local result = route.apply(observation, event, data)
  if result == false then
    return false
  end
  if result ~= 'terminal' then
    observation:read().sync[resource] = { state = 'current' }
  end
  return true
end

---@param connection OpencodeV2Connection
---@param event OpencodeV2Event
function M.route(connection, event)
  if not boundary.valid_event(event) then
    return
  end
  local route = routes[event.type]
  for _, observation in pairs(connection.observations) do
    local changed = {}
    if observation:_watches('children') and children_event(observation, event) then
      changed.children = true
    end
    if observation:_watches('files') and file_event(observation, event) then
      changed.files = true
    end

    local local_event = event.data.sessionID == observation._session_id
    if local_event and observation:_watches('messages') then
      local previous_sync = observation:read().sync.messages
      if messages.ingest_event(observation, event) or observation:read().sync.messages ~= previous_sync then
        changed.messages = true
      end
    end
    if route then
      local resource = route.resource
      local wanted = observation:_watches(resource)
        or (observation._local_operations > 0 and (resource == 'inbox' or resource == 'execution'))
      if wanted and (local_event or resource == 'questions') then
        local previous_sync = observation:read().sync[resource]
        if apply_event(observation, event, route) or observation:read().sync[resource] ~= previous_sync then
          changed[resource] = true
        end
      end
    end

    for resource in pairs(changed) do
      observation:_event_changed(resource)
    end
  end
end

---@param observation OpencodeV2Observation
function M.initialize(observation)
  observation._v2_inbox_terminal = {}
  observation._v2_permission_terminal = {}
  observation._v2_question_terminal = {}
  observation._v2_terminal_seen_since_start = false
  observation._v2_execution_event_active = false
end

return M
