local store = require('opencode.state.store')

---@class OpencodeContextStateMutations
local M = {}

---@param config OpencodeContextConfig|nil
function M.set_current_context_config(config)
  return store.set('current_context_config', config)
end

function M.update_current_context_config(mutator)
  return store.mutate('current_context_config', mutator)
end

---@param timestamp number|nil
function M.set_context_updated_at(timestamp)
  return store.set('context_updated_at', timestamp)
end

---@param cwd string|nil
function M.set_current_cwd(cwd)
  return store.set('current_cwd', cwd)
end

return M
