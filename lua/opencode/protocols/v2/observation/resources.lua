local Promise = require('opencode.promise')
local normalize = require('opencode.protocols.v2.normalize')
local boundary = require('opencode.protocols.v2.observation.boundary')
local messages = require('opencode.protocols.v2.observation.messages')

local M = {}

---@generic T
---@param value T
---@return Promise<T>
local function resolved(value)
  return Promise.new():resolve(value)
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
---@param items table[]
local function apply_inbox(observation, items)
  local state = observation:read()
  local result = { items_by_id = {}, order = {} }
  for _, item in ipairs(items) do
    local terminal = observation._v2_inbox_terminal[item.id]
    local mapped = normalize.mapped_inbox(item, terminal and terminal.status)
    if mapped.session_id ~= state.session.id then
      boundary.fail('inbox snapshot contains another session')
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

---@type table<OpencodeV2RemoteResource, fun(observation: OpencodeV2Observation, value: any)>
local apply = {}

---@param observation OpencodeV2Observation
---@param value table
apply.session = function(observation, value)
  local session = normalize.mapped_session(value)
  if session.id ~= observation:read().session.id then
    boundary.fail('session snapshot belongs to another session')
  end
  observation:read().session = session
end

---@param observation OpencodeV2Observation
---@param value table[]
apply.children = function(observation, value)
  local children = { by_id = {}, order = {} }
  for _, info in ipairs(value) do
    local child = normalize.mapped_session(info)
    if child.parentID ~= observation:read().session.id then
      boundary.fail('children snapshot contains another parent')
    end
    put_child(children, child)
  end
  observation:read().children = children
end

apply.messages = messages.apply_page

apply.inbox = apply_inbox

---@param observation OpencodeV2Observation
---@param value table<string, {type: 'running'}|nil>
apply.execution = function(observation, value)
  local state = observation:read()
  local active = value[state.session.id]
  if active then
    state.execution.activity = 'running'
  else
    state.execution.activity = 'idle'
    state.execution.last_outcome = state.session.outcome
    state.execution.last_idle = state.session.time and state.session.time.idle or nil
  end
end

---@param observation OpencodeV2Observation
---@param value table[]
apply.permissions = function(observation, value)
  local requests = {}
  for _, native in ipairs(value) do
    local request = normalize.mapped_permission(native)
    if request.session_id == observation:read().session.id then
      local terminal = observation._v2_permission_terminal[request.id]
      if terminal then
        request.status, request.answer = 'answered', terminal.answer
      end
      requests[request.id] = request
    end
  end
  observation:read().permission_requests_by_id = requests
end

---@param observation OpencodeV2Observation
---@param value table[]
apply.questions = function(observation, value)
  local requests = {}
  for _, native in ipairs(value) do
    local form = normalize.mapped_question(native)
    if form.session_id == observation:read().session.id then
      local terminal = observation._v2_question_terminal[form.id]
      if terminal then
        form.status = terminal.status
        form.answers = terminal.answers and vim.deepcopy(terminal.answers) or nil
      end
      requests[form.id] = form
    end
  end
  observation:read().question_requests_by_id = requests
end

---@param observation OpencodeV2Observation
---@param resource OpencodeV2RemoteResource
---@param value table
function M.apply(observation, resource, value)
  apply[resource](observation, value)
end

---@param observation OpencodeV2Observation
---@return Promise<OpencodeV2Session>
function M.ensure_session_location(observation)
  local session = observation:read().session
  local complete = type(session.location) == 'table'
    and type(session.location.directory) == 'string'
    and type(session.projectID) == 'string'
    and type(session.time) == 'table'
  if complete then
    ---@cast session OpencodeV2Session
    return resolved(session)
  end
  return observation._connection.operations
    .get_session(observation._connection, observation._session_id, nil)
    :and_then(function(value)
      local mapped = normalize.mapped_session(value)
      if mapped.id ~= observation._session_id then
        boundary.fail('session location belongs to another session')
      end
      observation:read().session = mapped
      return mapped
    end)
end

---@param observation OpencodeV2Observation
---@return Promise<table[]>
local function list_children(observation)
  local connection = observation._connection
  return Promise.async(function()
    local session = M.ensure_session_location(observation):await()
    local items = {}
    local cursor
    repeat
      local result = connection.operations.list_sessions(connection, session.location, cursor, 100, nil, nil):await()
      for _, info in ipairs(result.data) do
        if type(info) == 'table' and info.parentID == observation._session_id then
          items[#items + 1] = info
        end
      end
      cursor = result.cursor.next
    until cursor == nil
    return items
  end)()
end

---@param observation OpencodeV2Observation
---@param operation OpencodeLocationListOperation
---@return Promise<table[]>
local function location_list(observation, operation)
  return Promise.async(function()
    local session = M.ensure_session_location(observation):await()
    return operation(observation._connection, session.location, nil, nil):await()
  end)()
end

---@type table<OpencodeV2RemoteResource, fun(observation: OpencodeV2Observation, connection: OpencodeV2Connection): Promise<any>>
local requests = {
  ---@param observation OpencodeV2Observation
  ---@param connection OpencodeV2Connection
  ---@return Promise<table>
  session = function(observation, connection)
    return connection.operations.get_session(connection, observation._session_id, nil)
  end,
  ---@param observation OpencodeV2Observation
  ---@return Promise<table[]>
  children = function(observation)
    return list_children(observation)
  end,
  ---@param observation OpencodeV2Observation
  ---@param connection OpencodeV2Connection
  ---@return Promise<OpencodeV2Page<table>>
  messages = function(observation, connection)
    return connection.operations.list_messages(connection, observation._session_id, nil, 50, nil)
  end,
  ---@param observation OpencodeV2Observation
  ---@param connection OpencodeV2Connection
  ---@return Promise<table[]>
  inbox = function(observation, connection)
    return connection.operations.list_inbox(connection, observation._session_id, nil)
  end,
  ---@param _ OpencodeV2Observation
  ---@param connection OpencodeV2Connection
  ---@return Promise<table<string, {type: 'running'}>>
  execution = function(_, connection)
    return connection.operations.list_active_sessions(connection)
  end,
  ---@param observation OpencodeV2Observation
  ---@param connection OpencodeV2Connection
  ---@return Promise<table[]>
  permissions = function(observation, connection)
    return location_list(observation, connection.operations.list_permissions)
  end,
  ---@param observation OpencodeV2Observation
  ---@param connection OpencodeV2Connection
  ---@return Promise<table[]>
  questions = function(observation, connection)
    return location_list(observation, connection.operations.list_questions)
  end,
}

---@param observation OpencodeV2Observation
---@param resource OpencodeV2RemoteResource
---@return Promise<any>
function M.request(observation, resource)
  return requests[resource](observation, observation._connection)
end

return M
