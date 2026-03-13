local store = require('opencode.state.store')

local M = {}

---@param config OpencodeContextConfig|nil
function M.set_current_context_config(config)
  return store.set('current_context_config', config)
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
