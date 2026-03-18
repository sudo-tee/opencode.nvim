local store = require('opencode.state.store')

---@class OpencodeJobStateMutations
local M = {}

---@param delta integer|nil
function M.increment_count(delta)
  return store.update('job_count', function(current)
    return (current or 0) + (delta or 1)
  end)
end

---@param delta integer|nil
function M.decrement_count(delta)
  return store.update('job_count', function(current)
    return math.max(0, (current or 0) - (delta or 1))
  end)
end

---@param count integer
function M.set_count(count)
  return store.set('job_count', count)
end

---@param server OpencodeServer|nil
function M.set_server(server)
  return store.set('opencode_server', server)
end

function M.clear_server()
  return store.set('opencode_server', nil)
end

---@param client OpencodeApiClient|nil
function M.set_api_client(client)
  return store.set('api_client', client)
end

---@param manager EventManager|nil
function M.set_event_manager(manager)
  return store.set('event_manager', manager)
end

---@param version string|nil
function M.set_opencode_cli_version(version)
  return store.set('opencode_cli_version', version)
end

function M.is_running()
  return (store.get('job_count') or 0) > 0
end

return M
