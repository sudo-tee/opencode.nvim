local store = require('opencode.state.store')
local tabs = require('opencode.state.session_tabs')

local M = {}

---@class OpencodeProgramStatusRecord
---@field id string
---@field state string
---@field kind? string
---@field title? string

---@class OpencodeProgramStatusListener
---@field report fun(record: OpencodeProgramStatusRecord)
---@field is_viewed fun(tab_id: string): boolean

---@class OpencodeProgramStatusWatch
---@field session_id string
---@field observation OpencodeObservation
---@field connection OpencodeServer
---@field unwatch? fun()
---@field was_running boolean
---@field unseen_outcome? string Finished state kept until the tab is viewed.
---@field last_reported? OpencodeProgramStatusRecord

local RUNNING_ACTIVITIES = { running = true, retrying = true }
local OUTCOME_STATES = { succeeded = 'done', failed = 'error' }

---@type OpencodeProgramStatusListener?
local listener
---@type table<string, OpencodeProgramStatusWatch>
local watches = {}

---@param requests table<string, {status: string}|nil>
---@return boolean
local function has_pending(requests)
  ---@cast requests table<string, {status: string}> Pairs never yields absent entries.
  return vim.iter(requests):any(function(_, request)
    return request.status == 'pending'
  end)
end

---@param observed OpencodeObservationState
---@return string?
local function blocked_kind(observed)
  if has_pending(observed.permission_requests_by_id) then
    return 'permission'
  end
  if has_pending(observed.question_requests_by_id) then
    return 'question'
  end
end

---Guards against late callbacks from a watch whose tab, session, or server was replaced.
---@param id string
---@param watch OpencodeProgramStatusWatch
---@return boolean
local function is_current(id, watch)
  local runtime = tabs.get(id)
  local session = runtime and runtime.active_session
  return watches[id] == watch
    and session ~= nil
    and session.id == watch.observation:read().session.id
    and store.get('opencode_server') == watch.connection
    and watch.connection:is_ready()
end

---@param watch OpencodeProgramStatusWatch
---@param execution {activity: string, last_outcome?: string}
---@return string state
local function track_execution(watch, execution)
  if RUNNING_ACTIVITIES[execution.activity] then
    watch.was_running = true
    watch.unseen_outcome = nil
    return 'working'
  end
  if watch.was_running and execution.activity == 'idle' then
    watch.was_running = false
    -- V1's busy-to-idle transition alone cannot distinguish success from cancellation.
    watch.unseen_outcome = execution.last_outcome and OUTCOME_STATES[execution.last_outcome]
  end
  return watch.unseen_outcome or 'idle'
end

---@param id string
---@param watch OpencodeProgramStatusWatch
local function update(id, watch)
  if not listener or not is_current(id, watch) then
    return
  end

  local observed = watch.observation:read()
  local disconnected = observed.sync.execution.state == 'error'
  local state
  if disconnected then
    -- Events missed during a gap cannot establish a successful completion.
    watch.was_running = false
    state = watch.unseen_outcome or 'clear'
  else
    state = track_execution(watch, observed.execution)
  end
  if listener.is_viewed(id) then
    watch.unseen_outcome = nil
    if state ~= 'working' then
      state = disconnected and 'clear' or 'idle'
    end
  end

  local kind = not disconnected and blocked_kind(observed) or nil
  local record = {
    id = id,
    state = kind and 'blocked' or state,
    kind = kind,
    title = observed.session.title,
  }
  if not vim.deep_equal(watch.last_reported, record) then
    watch.last_reported = record
    listener.report(record)
  end
end

---@param id string
---@param observation OpencodeObservation
---@param previous? OpencodeProgramStatusWatch
---@return OpencodeProgramStatusWatch
local function add_watch(id, observation, previous)
  local watch = {
    session_id = observation:read().session.id,
    observation = observation,
    connection = observation._connection --[[@as OpencodeServer]],
    was_running = false,
    unseen_outcome = previous and previous.unseen_outcome,
    last_reported = previous and previous.last_reported,
  }
  watches[id] = watch
  watch.unwatch = observation:watch({ 'session', 'execution', 'permissions', 'questions' }, function()
    update(id, watch)
  end)
  return watch
end

---@param watch OpencodeProgramStatusWatch
local function unwatch(watch)
  local release = watch.unwatch
  watch.unwatch = nil
  if release then
    release()
  end
end

---@param id string
local function remove_watch(id)
  local watch = watches[id]
  watches[id] = nil
  unwatch(watch)
  if listener then
    listener.report({ id = id, state = 'clear' })
  end
end

---@return table<string, OpencodeObservation>
local function observe_open_tabs()
  local connection = store.get('opencode_server')
  if not connection or not connection:is_ready() then
    return {}
  end
  local observations = {}
  for _, runtime in ipairs(tabs.all()) do
    if runtime.active_session then
      observations[runtime.id] = connection:observe(runtime.active_session)
    end
  end
  return observations
end

function M.refresh()
  if not listener then
    return
  end
  local observations = observe_open_tabs()
  for id, watch in pairs(watches) do
    local runtime = tabs.get(id)
    local session = runtime and runtime.active_session
    local state = watch.last_reported and watch.last_reported.state
    if not session or session.id ~= watch.session_id then
      remove_watch(id)
    elseif observations[id] ~= watch.observation then
      unwatch(watch)
      -- Losing the connection does not acknowledge a finished result in an open tab.
      if (state ~= 'done' and state ~= 'error') or listener.is_viewed(id) then
        remove_watch(id)
      end
    end
  end
  for id, observation in pairs(observations) do
    local watch = watches[id]
    if not watch or not watch.unwatch then
      watch = add_watch(id, observation, watch)
    end
    update(id, watch)
  end
end

function M.stop()
  store.unsubscribe('session_tabs_changed', M.refresh)
  store.unsubscribe('active_session', M.refresh)
  store.unsubscribe('active_session_tab', M.refresh)
  store.unsubscribe('opencode_server', M.refresh)
  store.unsubscribe('is_opencode_focused', M.refresh)
  store.unsubscribe('windows', M.refresh)
  for id in pairs(watches) do
    remove_watch(id)
  end
  listener = nil
end

---Track only tab-owned observations. Never subscribe to child sessions or tool completion.
---Callbacks receive replacement records; failures propagate to the caller.
---@param report fun(record: OpencodeProgramStatusRecord)
---@param is_viewed fun(tab_id: string): boolean Whether this session's output is currently being viewed
function M.start(report, is_viewed)
  M.stop()
  listener = { report = report, is_viewed = is_viewed }
  store.subscribe('session_tabs_changed', M.refresh)
  store.subscribe('active_session', M.refresh)
  store.subscribe('active_session_tab', M.refresh)
  store.subscribe('opencode_server', M.refresh)
  store.subscribe('is_opencode_focused', M.refresh)
  store.subscribe('windows', M.refresh)
  M.refresh()
end

return M
