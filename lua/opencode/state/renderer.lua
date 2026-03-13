local store = require('opencode.state.store')

local M = {}

---@param messages OpencodeMessage[]|nil
function M.set_messages(messages)
  return store.set('messages', messages)
end

---@param message OpencodeMessage|nil
function M.set_current_message(message)
  return store.set('current_message', message)
end

---@param message OpencodeMessage|nil
function M.set_last_user_message(message)
  return store.set('last_user_message', message)
end

---@param permissions OpencodePermission[]
function M.set_pending_permissions(permissions)
  return store.set('pending_permissions', permissions)
end

---@param cost number
function M.set_cost(cost)
  return store.set('cost', cost)
end

---@param count number
function M.set_tokens_count(count)
  return store.set('tokens_count', count)
end

return M
