local store = require('opencode.state.store')

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

return M
