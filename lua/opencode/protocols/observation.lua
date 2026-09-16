local M = {}

local resource_names = {
  session = true,
  children = true,
  messages = true,
  inbox = true,
  execution = true,
  permissions = true,
  questions = true,
  files = true,
}

local Observation = {}
Observation.__index = Observation

function M.unread_sync()
  return { state = 'unread' }
end

function M.sync_error(source, err)
  local message = type(err) == 'table' and (err.message or err.code) or nil
  return {
    state = 'error',
    error = { kind = source, message = tostring(message or err or 'unknown error') },
  }
end

---@param session table
---@param unsupported? table<string, string>
function M.new_state(session, unsupported)
  local sync = {}
  for resource in pairs(resource_names) do
    local reason = unsupported and unsupported[resource]
    sync[resource] = reason and { state = 'unsupported', error = reason } or M.unread_sync()
  end
  return {
    session = session,
    entries_by_id = {},
    entry_order = {},
    children = { by_id = {}, order = {} },
    inbox = { items_by_id = {}, order = {} },
    execution = { activity = 'unknown' },
    permission_requests_by_id = {},
    question_requests_by_id = {},
    files = { revision = 0 },
    sync = sync,
  }
end

function Observation:read()
  return self._state
end

---Submit one prompt to a fresh, exclusively owned session and await its response.
---@param input table Protocol-independent submission input
---@return OpencodeReplyRequest
function Observation:request_reply(input)
  return require('opencode.protocols.reply').start(self, input, self._connection.protocol)
end

function Observation:_is_current()
  return self._connection:is_ready() and self._connection.observations[self._session_id] == self
end

function Observation:_watches(resource)
  for watcher in pairs(self._watchers) do
    if watcher.resources[resource] then
      return true
    end
  end
  return false
end

function Observation:_notify(resource)
  local callbacks = {}
  for watcher in pairs(self._watchers) do
    if watcher.resources[resource] then
      callbacks[#callbacks + 1] = watcher.changed
    end
  end
  for _, changed in ipairs(callbacks) do
    changed(self, resource)
  end
end

local function stream_resource(observation, resource)
  local select_resource = observation._runtime.stream_resource
  return not select_resource or select_resource(resource)
end

local function has_stream_demand(connection)
  if not connection:is_ready() then
    return false
  end
  for _, observation in pairs(connection.observations) do
    if observation._runtime then
      if observation._local_operations > 0 and observation._runtime.operations_need_stream ~= false then
        return true
      end
      for watcher in pairs(observation._watchers) do
        for resource in pairs(watcher.resources) do
          if stream_resource(observation, resource) then
            return true
          end
        end
      end
    end
  end
  return false
end

local function release_if_unused(observation)
  if next(observation._watchers) or observation._local_operations > 0 then
    return
  end
  if observation._connection.observations[observation._session_id] == observation then
    observation._connection.observations[observation._session_id] = nil
  end
  if observation._runtime.on_unused then
    observation._runtime.on_unused(observation)
  end
end

local function close_stream(connection)
  local retry = connection._observation_retry
  connection._observation_retry = nil
  if retry then
    retry:stop()
    retry:close()
  end
  local owner = connection._observation_stream
  connection._observation_stream = nil
  if not owner then
    return
  end
  if connection._stream == owner.handle then
    connection:set_stream(nil)
  end
  if owner.handle and owner.handle.shutdown then
    owner.handle:shutdown()
  end
end

function M.stop_stream_if_unused(connection)
  if not has_stream_demand(connection) then
    close_stream(connection)
  end
end

function Observation:_begin_local_operation()
  self._local_operations = self._local_operations + 1
  local active = true
  return function()
    if not active then
      return
    end
    active = false
    self._local_operations = self._local_operations - 1
    release_if_unused(self)
    M.stop_stream_if_unused(self._connection)
  end
end

function Observation:_fail_watched(source, message)
  for resource, sync in pairs(self._state.sync) do
    if self:_watches(resource) and sync.state ~= 'unsupported' then
      self._resource_generations[resource] = self._resource_generations[resource] + 1
      self._loading[resource] = nil
      self._state.sync[resource] = M.sync_error(source, message)
      self:_notify(resource)
    end
  end
end

local ensure_stream
local schedule_stream_recovery

local function stream_failure(connection, owner, reason)
  if connection._observation_stream ~= owner then
    return
  end
  close_stream(connection)
  local message = type(reason) == 'table' and tostring(reason.message or reason.code or 'event stream disconnected')
    or tostring(reason or 'event stream disconnected')
  for _, observation in pairs(connection.observations) do
    if observation._runtime then
      if observation._runtime.on_stream_error then
        observation._runtime.on_stream_error(observation, message)
      end
      observation:_fail_watched('event_stream', message)
    end
  end
  schedule_stream_recovery(connection)
end

local function decode_record(connection, owner)
  if #owner.data == 0 then
    return
  end
  local payload = table.concat(owner.data, '\n')
  owner.data = {}
  local ok, event = pcall(vim.json.decode, payload)
  if not ok or type(event) ~= 'table' then
    stream_failure(connection, owner, 'invalid ' .. owner.runtime.name .. ' event JSON')
    return
  end
  owner.runtime.route_event(connection, event)
end

local function consume_stream_chunk(connection, owner, chunk)
  if connection._observation_stream ~= owner or type(chunk) ~= 'string' then
    return
  end
  owner.buffer = owner.buffer .. chunk
  while true do
    local newline = owner.buffer:find('\n', 1, true)
    if not newline then
      return
    end
    local line = owner.buffer:sub(1, newline - 1):gsub('\r$', '')
    owner.buffer = owner.buffer:sub(newline + 1)
    if line == '' then
      decode_record(connection, owner)
      if connection._observation_stream ~= owner then
        return
      end
    else
      local data = line:match('^data:%s?(.*)$')
      if data then
        owner.data[#owner.data + 1] = data
      end
    end
  end
end

ensure_stream = function(connection, runtime)
  if connection._observation_stream then
    return
  end
  local owner = { buffer = '', data = {}, runtime = runtime }
  connection._observation_stream = owner
  local ok, handle = pcall(connection.operations.subscribe_events, connection, function(chunk)
    consume_stream_chunk(connection, owner, chunk)
  end, function(reason)
    stream_failure(connection, owner, reason)
  end)
  if not ok then
    if connection._observation_stream == owner then
      connection._observation_stream = nil
    end
    error(handle, 0)
  end
  owner.handle = handle
end

function M.ensure_stream(connection, observation)
  ensure_stream(connection, observation._runtime)
end

schedule_stream_recovery = function(connection)
  if not has_stream_demand(connection) or connection._observation_retry then
    return
  end
  local timer = vim.uv.new_timer()
  connection._observation_retry = timer
  timer:start(100, 0, vim.schedule_wrap(function()
    if connection._observation_retry ~= timer then
      return
    end
    connection._observation_retry = nil
    timer:stop()
    timer:close()
    if not has_stream_demand(connection) or connection._observation_stream then
      return
    end
    local observation
    for _, candidate in pairs(connection.observations) do
      if candidate._runtime then
        observation = candidate
        break
      end
    end
    local ok = observation and pcall(M.ensure_stream, connection, observation)
    if not ok then
      schedule_stream_recovery(connection)
      return
    end
    for _, candidate in pairs(connection.observations) do
      if candidate._runtime then
        for resource in pairs(candidate._resource_generations) do
          if candidate:_watches(resource) then
            candidate:_start_resource(resource)
          end
        end
      end
    end
  end))
end

local function can_apply_resource(observation, resource, generation)
  return observation:_is_current()
    and observation:_watches(resource)
    and observation._resource_generations[resource] == generation
end

function Observation:_start_resource(resource)
  local sync = self._state.sync[resource]
  if not sync or sync.state == 'unsupported' or self._loading[resource] or not self:_watches(resource) then
    return
  end
  if self._runtime.local_resource and self._runtime.local_resource(resource) then
    self._state.sync[resource] = { state = 'current' }
    self:_notify(resource)
    return
  end
  self._resource_generations[resource] = self._resource_generations[resource] + 1
  local generation = self._resource_generations[resource]
  local event_revision = self._event_revisions[resource]
  self._loading[resource] = generation
  self._state.sync[resource] = { state = 'loading' }
  self:_notify(resource)
  local ok, request = pcall(self._runtime.request_resource, self, resource)
  if not ok then
    self._loading[resource] = nil
    self._state.sync[resource] = M.sync_error('operation', request)
    self:_notify(resource)
    return
  end
  request
    :and_then(function(value)
      if not can_apply_resource(self, resource, generation) then
        return
      end
      self._loading[resource] = nil
      if self._event_revisions[resource] ~= event_revision then
        self._state.sync[resource] = { state = 'stale' }
        self:_notify(resource)
        self:_start_resource(resource)
        return
      end
      local applied, err = pcall(self._runtime.apply_resource, self, resource, value)
      if not applied then
        self._state.sync[resource] = M.sync_error('protocol_contract', err)
      elseif self._state.sync[resource].state == 'loading' then
        self._state.sync[resource] = { state = 'current' }
      end
      self:_notify(resource)
    end)
    :catch(function(err)
      if can_apply_resource(self, resource, generation) then
        self._loading[resource] = nil
        self._state.sync[resource] = M.sync_error('operation', err)
        self:_notify(resource)
      end
    end)
end

function Observation:_release_resource(resource)
  if self._state.sync[resource].state == 'unsupported' then
    return
  end
  self._resource_generations[resource] = self._resource_generations[resource] + 1
  self._loading[resource] = nil
  local state = self._state
  if resource == 'session' then
    state.session = vim.deepcopy(self._session_ref)
  elseif resource == 'children' then
    state.children = { by_id = {}, order = {} }
  elseif resource == 'messages' then
    state.entries_by_id, state.entry_order = {}, {}
  elseif resource == 'inbox' then
    state.inbox = { items_by_id = {}, order = {} }
  elseif resource == 'execution' then
    state.execution = { activity = 'unknown' }
  elseif resource == 'permissions' then
    state.permission_requests_by_id = {}
  elseif resource == 'questions' then
    state.question_requests_by_id = {}
  elseif resource == 'files' then
    state.files = { revision = 0 }
  end
  if self._runtime.on_release_resource then
    self._runtime.on_release_resource(self, resource)
  end
  state.sync[resource] = M.unread_sync()
end

function Observation:watch(resources, changed)
  if type(resources) ~= 'table' or type(changed) ~= 'function' then
    error('watch requires resources and a changed callback')
  end
  local selected, previous = {}, {}
  for _, resource in ipairs(resources) do
    if not resource_names[resource] then
      error('unsupported Observation resource: ' .. tostring(resource))
    end
    selected[resource] = true
    previous[resource] = self:_watches(resource)
  end
  local watcher = { resources = selected, changed = changed }
  self._watchers[watcher] = true
  local ok, err = pcall(function()
    if has_stream_demand(self._connection) then
      M.ensure_stream(self._connection, self)
    end
    for resource in pairs(previous) do
      if not previous[resource] then
        self:_start_resource(resource)
      end
    end
  end)
  if not ok then
    self._watchers[watcher] = nil
    release_if_unused(self)
    error(err, 0)
  end
  local subscribed = true
  return function()
    if not subscribed then
      return
    end
    subscribed = false
    self._watchers[watcher] = nil
    for resource in pairs(previous) do
      if not self:_watches(resource) then
        self:_release_resource(resource)
      end
    end
    release_if_unused(self)
    M.stop_stream_if_unused(self._connection)
  end
end

---@param connection table
---@param session table
---@param state table
---@param runtime table
function M.attach(connection, session, state, runtime)
  local generations, revisions = {}, {}
  for resource in pairs(resource_names) do
    generations[resource], revisions[resource] = 0, 0
  end
  return setmetatable({
    _connection = connection,
    _session_id = session.id,
    _session_ref = vim.deepcopy(session),
    _state = state,
    _runtime = runtime,
    _watchers = {},
    _local_operations = 0,
    _loading = {},
    _resource_generations = generations,
    _event_revisions = revisions,
  }, Observation)
end

function M.close(connection)
  close_stream(connection)
  for _, observation in pairs(connection.observations) do
    if observation._runtime and observation._runtime.on_close then
      observation._runtime.on_close(observation)
    end
  end
  connection.observations = {}
end

return M
