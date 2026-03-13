local store = require('opencode.state.store')

---@class OpencodeSessionStateMutations
---@field set_active fun(session: Session|nil, opts?: OpencodeProtectedStateSetOptions)
---@field clear_active fun(opts?: OpencodeProtectedStateSetOptions)
---@field set_restore_points fun(points: RestorePoint[], opts?: OpencodeProtectedStateSetOptions)
---@field reset_restore_points fun(opts?: OpencodeProtectedStateSetOptions)
---@field set_last_sent_context fun(context: OpencodeContext|nil)
---@field set_user_message_count fun(count: table<string, number>)

local M = {}

---@param session Session|nil
---@param opts? OpencodeProtectedStateSetOptions
function M.set_active(session, opts)
  return store.set('active_session', session, opts)
end

---@param opts? OpencodeProtectedStateSetOptions
function M.clear_active(opts)
  return store.set('active_session', nil, opts)
end

---@param points RestorePoint[]
---@param opts? OpencodeProtectedStateSetOptions
function M.set_restore_points(points, opts)
  return store.set('restore_points', points, opts)
end

---@param opts? OpencodeProtectedStateSetOptions
function M.reset_restore_points(opts)
  return store.set('restore_points', {}, opts)
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
