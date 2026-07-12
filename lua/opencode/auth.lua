local config = require('opencode.config')

local M = {}

local cache = nil

--- Resolve a credential value that may be a string or a function returning a string.
--- Returns nil for nil, empty string, or function errors.
---@param val string | (fun(): string | nil) | nil
---@return string | nil
local function resolve_credential(val)
  if type(val) == 'function' then
    local ok, result = pcall(val)
    if ok and result and result ~= '' then
      return result
    end
    return nil
  end
  if val and val ~= '' then
    return val
  end
  return nil
end

--- Resolve and cache credentials from config + env vars.
---@return string|nil password
---@return string username
local function ensure_resolved()
  if cache then
    return cache.password, cache.username
  end

  local password = resolve_credential(config.server.password)
    or vim.env.OPENCODE_SERVER_PASSWORD
  local username = resolve_credential(config.server.username)
    or vim.env.OPENCODE_SERVER_USERNAME
    or 'opencode'

  cache = {
    password = password,
    username = username,
  }

  return cache.password, cache.username
end

--- Reset cached credentials. Call after changing config values.
function M.clear_cache()
  cache = nil
end

--- Resolve credentials and return Authorization headers for HTTP Basic Auth.
--- Returns an empty table if no password is configured (server doesn't require auth).
---@return table<string, string> headers
function M.get_auth_headers()
  local password, username = ensure_resolved()
  if not password then
    return {}
  end

  local encoded = vim.base64.encode(username .. ':' .. password)
  return { ['Authorization'] = 'Basic ' .. encoded }
end
