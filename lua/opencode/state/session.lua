local store = require('opencode.state.store')

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

return M
