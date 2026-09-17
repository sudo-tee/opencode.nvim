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

---@alias OpencodeObservedResource 'session'|'children'|'messages'|'inbox'|'execution'|'permissions'|'questions'|'files'

---Adapters interpret native payloads; the shared lifecycle owns requests and publication.
---@class OpencodeObservationRuntime
---@field name string
---@field request_resource fun(observation: OpencodeObservation, resource: OpencodeObservedResource): Promise
---@field apply_resource fun(observation: OpencodeObservation, resource: OpencodeObservedResource, value: any) Validate and commit a snapshot; must not publish it
---@field route_event fun(connection: table, event: table) Commit native event data, then call _event_changed for affected resources
---@field refresh_after_event fun(resource: OpencodeObservedResource, sync: table): boolean Whether published events leave the resource needing a fresh snapshot
---@field find_reply fun(observation: OpencodeObservation, input_id: string): table|nil
---@field local_resource? fun(resource: OpencodeObservedResource): boolean
---@field stream_resource? fun(resource: OpencodeObservedResource): boolean
---@field operations_need_stream? boolean Defaults to true
---@field on_release_resource? fun(observation: OpencodeObservation, resource: OpencodeObservedResource)
---@field on_unused? fun(observation: OpencodeObservation)
---@field on_stream_error? fun(observation: OpencodeObservation, message: string)
---@field on_close? fun(observation: OpencodeObservation)

---@class OpencodeObservation
---@field _connection table
---@field _session_id string
---@field _session_ref table
---@field _state table Mutable normalized state, owned by this observation
---@field _runtime OpencodeObservationRuntime
---@field _watchers table<table, boolean>
---@field _local_operations integer Operations retain the observation even without watchers
---@field _loading table<OpencodeObservedResource, {revision: integer}> One active snapshot token per resource
---@field _event_revisions table<OpencodeObservedResource, integer>
local Observation = {}
Observation.__index = Observation

--- Decode an editor-context payload (selection / diagnostics / cursor-data /
--- file-content / git-diff) into the protocol-neutral contract entry.
--- Both protocol adapters map their wire shapes onto this one: V1 carries it
--- as a synthetic text part with metadata.context_type, V2 as a file
--- attachment whose name is prefixed with "editor-context:".
--- @param context_type string the wire-declared context type
--- @param text string JSON payload for selection/diagnostics/cursor-data,
---                    plain text for file-content/git-diff
--- @param part_id string stable identity for the rendered entry
--- @param synthetic boolean|nil
--- @param ignored boolean|nil
--- @return table|nil entry
--- @return string|nil err
function M.decode_editor_context(context_type, text, part_id, synthetic, ignored)
  local base = { id = part_id, kind = 'editor_context', synthetic = synthetic, ignored = ignored }

  if context_type == 'file-content' then
    base.source = { kind = 'buffer', media_type = 'text/plain' }
    base.text = text
    return base
  end
  if context_type == 'git-diff' then
    base.source = { kind = 'git_diff' }
    base.text = text
    return base
  end
  if context_type ~= 'selection' and context_type ~= 'diagnostics' and context_type ~= 'cursor-data' then
    return nil, 'unsupported editor context type: ' .. tostring(context_type)
  end

  local ok, decoded = pcall(vim.json.decode, text)
  if not ok or type(decoded) ~= 'table' or decoded.context_type ~= context_type then
    return nil, 'invalid ' .. tostring(context_type) .. ' editor context JSON'
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

  -- cursor-data
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

---Empty state per resource. A new state seeds itself from these and releasing a
---resource restores them, so the two cannot drift apart. `session` is absent: its
---empty value is the observation's own session reference.
---@type table<OpencodeObservedResource, fun(state: table)>
local clear_state = {
  children = function(state)
    state.children = { by_id = {}, order = {} }
  end,
  messages = function(state)
    state.entries_by_id, state.entry_order = {}, {}
  end,
  inbox = function(state)
    state.inbox = { items_by_id = {}, order = {} }
  end,
  execution = function(state)
    state.execution = { activity = 'unknown' }
  end,
  permissions = function(state)
    state.permission_requests_by_id = {}
  end,
  questions = function(state)
    state.question_requests_by_id = {}
  end,
  files = function(state)
    state.files = { revision = 0 }
  end,
}

---@param session table
---@param unsupported? table<string, string>
function M.new_state(session, unsupported)
  local sync = {}
  for resource in pairs(resource_names) do
    local reason = unsupported and unsupported[resource]
    sync[resource] = reason and { state = 'unsupported', error = reason } or M.unread_sync()
  end
  local state = { session = session, sync = sync }
  for _, clear in pairs(clear_state) do
    clear(state)
  end
  return state
end

---Borrow the current state. Consumers must not mutate it or use identity to detect changes.
---@return table
function Observation:read()
  return self._state
end

---Submit one prompt to a fresh, exclusively owned session and await its response.
---@param input table Protocol-independent submission input
---@return OpencodeReplyRequest
function Observation:request_reply(input)
  return require('opencode.protocols.reply').start(self, input)
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

---Publish committed event data before evaluating the protocol's refresh policy.
---@param resource OpencodeObservedResource
function Observation:_event_changed(resource)
  self._event_revisions[resource] = self._event_revisions[resource] + 1
  self:_notify(resource)
  if self._runtime.refresh_after_event(resource, self._state.sync[resource]) then
    self:_start_resource(resource)
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

---@param operation function
---@param ... any Operation arguments after the connection
---@return Promise
function Observation:_start_action(operation, ...)
  local finish = self:_begin_local_operation()
  local ok, request = pcall(operation, self._connection, ...)
  if not ok then
    finish()
    error(request, 0)
  end
  return request:finally(finish)
end

function Observation:_fail_watched(source, message)
  for resource, sync in pairs(self._state.sync) do
    if self:_watches(resource) and sync.state ~= 'unsupported' then
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
    if observation._runtime.on_stream_error then
      observation._runtime.on_stream_error(observation, message)
    end
    observation:_fail_watched('event_stream', message)
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

local RECOVERY_DELAY_MS = 100

---Reopen the shared stream for a connection that still has demand.
---@return boolean reopened Whether watched resources should be reloaded
local function retry_stream(connection)
  if not has_stream_demand(connection) or connection._observation_stream then
    return false
  end
  local _, observation = next(connection.observations)
  if not (observation and pcall(M.ensure_stream, connection, observation)) then
    schedule_stream_recovery(connection)
    return false
  end
  return true
end

local function reload_watched_resources(connection)
  for _, observation in pairs(connection.observations) do
    for resource in pairs(resource_names) do
      if observation:_watches(resource) then
        observation:_start_resource(resource)
      end
    end
  end
end

schedule_stream_recovery = function(connection)
  if not has_stream_demand(connection) or connection._observation_retry then
    return
  end
  local timer = vim.uv.new_timer()
  connection._observation_retry = timer
  timer:start(
    RECOVERY_DELAY_MS,
    0,
    vim.schedule_wrap(function()
      if connection._observation_retry ~= timer then
        return
      end
      connection._observation_retry = nil
      timer:stop()
      timer:close()
      if retry_stream(connection) then
        reload_watched_resources(connection)
      end
    end)
  )
end

function Observation:_start_resource(resource)
  if not self:_is_current() then
    return
  end
  local sync = self._state.sync[resource]
  if not sync or sync.state == 'unsupported' or self._loading[resource] or not self:_watches(resource) then
    return
  end
  if self._runtime.local_resource and self._runtime.local_resource(resource) then
    self._state.sync[resource] = { state = 'current' }
    self:_notify(resource)
    return
  end

  -- Only the token still stored in `_loading` may commit its response. Release and
  -- stream loss clear it, so holding it also proves a watcher still wants the snapshot.
  local token = { revision = self._event_revisions[resource] }
  self._loading[resource] = token
  local function owns_request()
    return self:_is_current() and self._loading[resource] == token
  end
  local function failed(err)
    if owns_request() then
      self._loading[resource] = nil
      self._state.sync[resource] = M.sync_error('operation', err)
      self:_notify(resource)
    end
  end

  self._state.sync[resource] = { state = 'loading' }
  self:_notify(resource)
  if not owns_request() then
    return
  end
  local ok, request = pcall(self._runtime.request_resource, self, resource)
  if not ok then
    failed(request)
    return
  end
  request
    :and_then(function(value)
      if not owns_request() then
        return
      end
      self._loading[resource] = nil
      if self._event_revisions[resource] ~= token.revision then
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
    :catch(failed)
end

function Observation:_release_resource(resource)
  if self._state.sync[resource].state == 'unsupported' then
    return
  end
  self._loading[resource] = nil
  local state = self._state
  if resource == 'session' then
    state.session = vim.deepcopy(self._session_ref)
  else
    clear_state[resource](state)
  end
  if self._runtime.on_release_resource then
    self._runtime.on_release_resource(self, resource)
  end
  state.sync[resource] = M.unread_sync()
end

---The last unsubscribe for a resource clears its state and invalidates its pending snapshot.
---@param resources OpencodeObservedResource[]
---@param changed fun(observation: OpencodeObservation, resource: OpencodeObservedResource)
---@return fun() unsubscribe
function Observation:watch(resources, changed)
  if type(resources) ~= 'table' or type(changed) ~= 'function' then
    error('watch requires resources and a changed callback')
  end
  local selected, to_start = {}, {}
  for _, resource in ipairs(resources) do
    if not resource_names[resource] then
      error('unsupported Observation resource: ' .. tostring(resource))
    end
    if not selected[resource] and not self:_watches(resource) then
      to_start[#to_start + 1] = resource
    end
    selected[resource] = true
  end
  local watcher = { resources = selected, changed = changed }
  self._watchers[watcher] = true
  local ok, err = pcall(function()
    if has_stream_demand(self._connection) then
      M.ensure_stream(self._connection, self)
    end
    for _, resource in ipairs(to_start) do
      self:_start_resource(resource)
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
    for resource in pairs(selected) do
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
---@param runtime OpencodeObservationRuntime
---@return OpencodeObservation
function M.attach(connection, session, state, runtime)
  local revisions = {}
  for resource in pairs(resource_names) do
    revisions[resource] = 0
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
    _event_revisions = revisions,
  }, Observation)
end

function M.close(connection)
  close_stream(connection)
  for _, observation in pairs(connection.observations) do
    if observation._runtime.on_close then
      observation._runtime.on_close(observation)
    end
  end
  connection.observations = {}
end

return M
