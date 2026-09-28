local store = require('opencode.state.store')

---@class OpencodeRendererStateMutations
local M = {}

---@param messages OpencodeMessage[]|nil
function M.set_messages(messages)
  return store.set('messages', messages)
end

---@param message OpencodeMessage|nil
function M.set_current_message(message)
  return store.set('current_message', message)
end

---@param permissions OpencodePermission[]
function M.set_pending_permissions(permissions)
  return store.set('pending_permissions', permissions)
end

---@param mutator fun(current_permissions: OpencodePermission[]): nil
function M.update_pending_permissions(mutator)
  return store.mutate('pending_permissions', mutator)
end

---@param cost number
function M.set_cost(cost)
  if cost == nil then
    return
  end
  return store.set('cost', cost)
end

---@param count number
function M.set_tokens_count(count)
  return store.set('tokens_count', count)
end

function M.reset()
  return store.batch(function()
    store.set('messages', {})
    store.set('current_message', nil)
    store.set('tokens_count', 0)
    store.set('pending_permissions', {})
  end)
end

return M
