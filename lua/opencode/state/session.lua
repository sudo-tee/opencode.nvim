local store = require('opencode.state.store')

---@class OpencodeSessionStateMutations
local M = {}

---@param session Session|nil
function M.set_active(session)
  return store.batch(function()
    store.set('restore_points', {})
    store.set('last_sent_context', nil)
    store.set('user_message_count', {})
    return store.set('active_session', session)
  end)
end

function M.clear_active()
  return store.batch(function()
    store.set('restore_points', {})
    store.set('last_sent_context', nil)
    store.set('user_message_count', {})
    return store.set('active_session', nil)
  end)
end

---@param points RestorePoint[]
function M.set_restore_points(points)
  return store.set('restore_points', points)
end

function M.reset_restore_points()
  return store.set('restore_points', {})
end

---@param context OpencodeContext|nil
function M.set_last_sent_context(context)
  return store.set('last_sent_context', context)
end

---@param count table<string, number>
function M.set_user_message_count(count)
  return store.set('user_message_count', count)
end

return M
