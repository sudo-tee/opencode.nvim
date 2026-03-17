local store = require('opencode.state.store')

---@class OpencodeJobStateMutations
---@field increment_count fun(delta?: integer)
---@field decrement_count fun(delta?: integer)
---@field set_count fun(count: integer)
---@field set_server fun(server: OpencodeServer|nil)
---@field clear_server fun()
---@field set_api_client fun(client: OpencodeApiClient|nil)
---@field set_event_manager fun(manager: EventManager|nil)
---@field set_opencode_cli_version fun(version: string|nil)
---@field is_running fun():boolean

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
