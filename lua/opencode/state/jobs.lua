local store = require('opencode.state.store')

---@class OpencodeJobStateMutations
---@field increment_count fun(delta?: integer, opts?: OpencodeProtectedStateSetOptions)
---@field decrement_count fun(delta?: integer, opts?: OpencodeProtectedStateSetOptions)
---@field set_count fun(count: integer, opts?: OpencodeProtectedStateSetOptions)
---@field set_server fun(server: OpencodeServer|nil, opts?: OpencodeProtectedStateSetOptions)
---@field clear_server fun(opts?: OpencodeProtectedStateSetOptions)
---@field set_api_client fun(client: OpencodeApiClient|nil)
---@field set_event_manager fun(manager: EventManager|nil)
---@field set_opencode_cli_version fun(version: string|nil)

local M = {}

---@param delta integer|nil
---@param opts? OpencodeProtectedStateSetOptions
function M.increment_count(delta, opts)
  return store.update('job_count', function(current)
    return (current or 0) + (delta or 1)
  end, opts)
end

---@param delta integer|nil
---@param opts? OpencodeProtectedStateSetOptions
function M.decrement_count(delta, opts)
  return store.update('job_count', function(current)
    return math.max(0, (current or 0) - (delta or 1))
  end, opts)
end

---@param count integer
---@param opts? OpencodeProtectedStateSetOptions
function M.set_count(count, opts)
  return store.set('job_count', count, opts)
end

---@param server OpencodeServer|nil
---@param opts? OpencodeProtectedStateSetOptions
function M.set_server(server, opts)
  return store.set('opencode_server', server, opts)
end

---@param opts? OpencodeProtectedStateSetOptions
function M.clear_server(opts)
  return store.set('opencode_server', nil, opts)
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

return M
