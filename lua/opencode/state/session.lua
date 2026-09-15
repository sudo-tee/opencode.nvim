local store = require('opencode.state.store')
local session_tabs = require('opencode.state.session_tabs')

---@class OpencodeSessionStateMutations
local M = {}

---@param session Session|nil
function M.set_active(session)
  local previous = store.get('active_session')
  local previous_id = type(previous) == 'table' and previous.id or nil
  local session_id = type(session) == 'table' and session.id or nil
  if previous_id ~= session_id then
    local runtime = session_tabs.current()
    if runtime then
      session_tabs.clear_pending_prompts(runtime.id)
    end
  end

  local result = store.batch(function()
    store.set('restore_points', {})
    store.set('last_sent_context', nil)
    store.set('user_message_count', {})
    return store.set('active_session', session)
  end)
  session_tabs.sync()
  return result
end

function M.clear_active()
  if store.get('active_session') then
    local runtime = session_tabs.current()
    if runtime then
      session_tabs.clear_pending_prompts(runtime.id)
    end
  end

  local result = store.batch(function()
    store.set('restore_points', {})
    store.set('last_sent_context', nil)
    store.set('user_message_count', {})
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

---Update active_session without emitting a change event, used when a silent
---in-place update is needed (e.g. session metadata refresh that must not
---trigger a re-render)
---@param session Session
function M.update_silently(session)
  store.set_raw('active_session', session)
  session_tabs.sync()
end

return M
