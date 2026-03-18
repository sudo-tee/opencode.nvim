
local store = require('opencode.state.store')

---@class OpencodeRendererStateMutations
---@field set_messages fun(messages: OpencodeMessage[]|nil)
---@field set_current_message fun(message: OpencodeMessage|nil)
---@field set_last_user_message fun(message: OpencodeMessage|nil)
---@field set_pending_permissions fun(permissions: OpencodePermission[])
---@field set_cost fun(cost: number)
---@field set_tokens_count fun(count: number)
---@field set_stats fun(tokens_count: number, cost: number)
---@field reset fun()

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

---@param tokens_count number
---@param cost number
function M.set_stats(tokens_count, cost)
  store.set('tokens_count', tokens_count)
  store.set('cost', cost)
end

function M.reset()
  store.set('messages', {})
  store.set('last_user_message', nil)
  store.set('tokens_count', 0)
  store.set('cost', 0)
  store.set('pending_permissions', {})
end

return M
