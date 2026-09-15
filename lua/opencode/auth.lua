local M = {}

--- Convert an already resolved credential to Basic Auth headers.
--- Returns an empty table if no password is configured (server doesn't require auth).
---@return table<string, string> headers
function M.get_auth_headers(credential)
  credential = credential or {}
  local password, username = credential.password, credential.username or 'opencode'
  if not password then
    return {}
  end

  local encoded = vim.base64.encode(username .. ':' .. password)
  return { ['Authorization'] = 'Basic ' .. encoded }
end

--- Convert an already resolved credential to environment variables for a spawned server.
--- Returns an empty table if no password is configured.
---@return table<string, string> env
function M.get_env(credential)
  credential = credential or {}
  local password, username = credential.password, credential.username or 'opencode'
  if not password then
    return {}
  end

  return {
    OPENCODE_PASSWORD = password,
    OPENCODE_SERVER_PASSWORD = password,
    OPENCODE_SERVER_USERNAME = username,
  }
end

return M
