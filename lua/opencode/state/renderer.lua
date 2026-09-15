local store = require('opencode.state.store')

---@class OpencodeRendererStateMutations
local M = {}

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
    store.set('tokens_count', 0)
    store.set('pending_permissions', {})
  end)
end

return M
