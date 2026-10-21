local store = require('opencode.state.store')
local session_tabs = require('opencode.state.session_tabs')

---@class OpencodeSessionStateMutations
local M = {}

---The active tab is the session owner; the store only projects it.
---A session never migrates between tabs: activating a session someone else owns
---activates that owner instead.
---@param session OpencodeSession|nil
local function bind_active_tab(session)
  local runtime = session_tabs.current()
  if not runtime then
    return
  end
  local owner = session and session.id and session_tabs.owner_of(session.id)
  if owner and owner.id ~= runtime.id then
    session_tabs.activate(owner)
    return
  end
  session_tabs.set_session(runtime, session)
end

---@param session OpencodeSession|nil
function M.set_active(session)
  local ref
  if session then
    if type(session.id) ~= 'string' or session.id == '' then
      error('active session requires an id')
    end
    local location = session.location
    if location == nil and type(session.directory) == 'string' then
      location = { directory = session.directory }
    end
    ref = { id = session.id, location = vim.deepcopy(location), title = session.title }
  end
  local previous = store.get('active_session')
  local previous_id = type(previous) == 'table' and previous.id or nil
  if previous_id ~= (ref and ref.id or nil) then
    local runtime = session_tabs.current()
    if runtime then
      runtime.model_restored_session_id = nil
      session_tabs.clear_pending_prompts(runtime.id)
    end
  end

  bind_active_tab(ref)
  local result = store.batch(function()
    store.set('restore_points', {})
    store.set('last_sent_context', nil)
    store.set('user_message_count', {})
    store.set('cost', type(session) == 'table' and session.cost or 0)
    return store.set('active_session', ref)
  end)
  session_tabs.sync()
  return result
end

---@param session OpencodeSession
---@return table|nil
function M.update_active_metadata(session)
  local active = store.get('active_session')
  if type(active) ~= 'table' or type(session) ~= 'table' or active.id ~= session.id then
    return active
  end

  local location = session.location
  if location == nil and type(session.directory) == 'string' then
    location = { directory = session.directory }
  end
  local updated = { id = active.id, location = vim.deepcopy(location or active.location), title = session.title }
  if vim.deep_equal(active, updated) then
    return active
  end

  bind_active_tab(updated)
  local result = store.set('active_session', updated)
  session_tabs.sync()
  return result
end

---@return OpencodeObservation|nil
function M.active_observation()
  local ref = store.get('active_session')
  local connection = store.get('opencode_server')
  if not ref or not connection or not connection:is_ready() then
    return nil
  end
  return connection:observe(ref)
end

function M.clear_active()
  if store.get('active_session') then
    local runtime = session_tabs.current()
    if runtime then
      runtime.model_restored_session_id = nil
      session_tabs.clear_pending_prompts(runtime.id)
    end
  end

  bind_active_tab(nil)
  local result = store.batch(function()
    store.set('restore_points', {})
    store.set('last_sent_context', nil)
    store.set('user_message_count', {})
    store.set('cost', 0)
    return store.set('active_session', nil)
  end)
  session_tabs.sync()
  return result
end

---@return boolean
function M.is_locked()
  return store.get('session_locked') == true
end

---@param value boolean|nil nil = inherit default
function M.set_locked(value)
  if value == nil then
    store.set_raw('session_locked', nil)
  else
    store.set('session_locked', value and true or false)
  end
  session_tabs.sync()
end

---@return boolean new_value
function M.toggle_locked()
  local new_value = not M.is_locked()
  M.set_locked(new_value)
  return new_value
end

---@param points RestorePoint[]
function M.set_restore_points(points)
  local result = store.set('restore_points', points)
  session_tabs.sync()
  return result
end

function M.reset_restore_points()
  local result = store.set('restore_points', {})
  session_tabs.sync()
  return result
end

---@param context OpencodeContext|nil
function M.set_last_sent_context(context)
  local result = store.set('last_sent_context', context)
  session_tabs.sync()
  return result
end

---@param count table<string, number>
function M.set_user_message_count(count)
  local result = store.set('user_message_count', count)
  session_tabs.sync()
  return result
end

return M
