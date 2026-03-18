local store = require('opencode.state.store')

---@class OpencodeSessionStateMutations
---@field set_active fun(session: Session|nil)
---@field clear_active fun()
---@field set_restore_points fun(points: RestorePoint[])
---@field reset_restore_points fun()
---@field set_last_sent_context fun(context: OpencodeContext|nil)
---@field set_user_message_count fun(count: table<string, number>)

local M = {}

---@param session Session|nil
function M.set_active(session)
  store.set('restore_points', {})
  store.set('last_sent_context', nil)
  store.set('user_message_count', {})
  return store.set('active_session', session)
end

function M.clear_active()
  M.reset_restore_points()
  M.set_last_sent_context()
  M.set_user_message_count({})
  return store.set('active_session', nil)
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
