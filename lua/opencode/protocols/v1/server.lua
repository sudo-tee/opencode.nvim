local config = require('opencode.config')

local M = {}

---@return number|string|nil
function M.configured_port()
  local port = config.server.port
  if port ~= nil and port ~= 'auto' then
    return port
  end
end

---@param port number|string
---@return string
function M.endpoint(port)
  return string.format('http://127.0.0.1:%s', port)
end

---@param port? number|string
---@return string|nil
function M.credential_file(port)
  if config.server.password_file ~= nil and config.server.password_file ~= '' then
    return config.server.password_file
  end
  if port then
    return string.format('%s/opencode/v1-%s.password', vim.fn.stdpath('state'), port)
  end
end

---@param port? number|string
---@param hostname? string
---@return string[]
function M.command(port, hostname)
  local command = { config.opencode_executable, 'serve' }
  if port then
    command[#command + 1] = '--port'
    command[#command + 1] = tostring(port)
  end
  if hostname then
    hostname = hostname:gsub('^%a[%w+%.%-]*://', '')
    hostname = hostname:match('^[^/]+') or hostname
    command[#command + 1] = '--hostname'
    command[#command + 1] = hostname
  end
  return command
end

---@param output string
---@return string|nil
function M.listening_url(output)
  return output:match('server listening on ([^%s]+)')
end

return M
