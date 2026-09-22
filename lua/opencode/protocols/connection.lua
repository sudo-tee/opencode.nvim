local Promise = require('opencode.promise')
local curl = require('opencode.curl')
local auth = require('opencode.auth')

local adapters = {
  v1 = require('opencode.protocols.v1.connection'),
  v2 = require('opencode.protocols.v2.connection'),
}

local M = {}

---@param response? {status: integer, headers?: table<string, string>, body: string}
---@param endpoint string
---@return string
local function invalid_response(response, endpoint)
  local status = response and response.status or 'none'
  local headers = response and response.headers or {}
  local content_type = headers['content-type'] or 'unknown'
  local body_bytes = response and #(response.body or '') or 0
  return string.format(
    'invalid health response from %s (status=%s, content-type=%s, body-bytes=%d)',
    endpoint,
    tostring(status),
    content_type,
    body_bytes
  )
end

---@param response? {status: integer, headers?: table<string, string>, body: string}
---@param endpoint string
---@return table|nil body
---@return string|nil error
local function decode_json(response, endpoint)
  if not response then
    return nil, 'health probe returned no response'
  end
  if type(response.status) ~= 'number' then
    return nil, invalid_response(response, endpoint)
  end
  if response.status == 401 or response.status == 403 then
    return nil, 'credential error'
  end
  if response.status < 200 or response.status >= 300 then
    return nil, 'health probe HTTP ' .. response.status
  end
  local ok, body = pcall(vim.json.decode, response.body or '')
  if not ok or type(body) ~= 'table' then
    return nil, invalid_response(response, endpoint)
  end
  return body
end

---@param connection OpencodeServer
---@param adapter table
---@param timeout_ms? number
---@param callback fun(response: table)
---@param on_error fun(err: any)
local function request(connection, adapter, timeout_ms, callback, on_error)
  ---@cast connection.url string
  curl.request({
    url = connection.url:gsub('/$', '') .. adapter.health_path,
    method = 'GET',
    headers = auth.get_auth_headers(connection.credential),
    timeout = timeout_ms or 2000,
    proxy = '',
    callback = callback,
    on_error = on_error,
  })
end

---@param connection OpencodeServer
---@param timeout_ms? number
---@return Promise<{protocol: 'v1'|'v2', response: table}>
function M.probe(connection, timeout_ms)
  local result = Promise.new()

  local function reject_transport(err)
    result:reject({ kind = 'transport', cause = err })
  end

  local function probe_v1()
    local adapter = adapters.v1
    request(connection, adapter, timeout_ms, function(response)
      local body, err = adapter.decode_probe(response, decode_json, invalid_response)
      if not body then
        result:reject(err)
        return
      end
      result:resolve({ protocol = adapter.name, response = body })
    end, reject_transport)
  end

  local adapter = adapters.v2
  request(connection, adapter, timeout_ms, function(response)
    local body, err, fallback = adapter.decode_probe(response, decode_json)
    if fallback then
      probe_v1()
    elseif not body then
      result:reject(err)
    else
      result:resolve({ protocol = adapter.name, response = body })
    end
  end, reject_transport)

  return result
end

---@param protocol 'v1'|'v2'
---@return {operations: table, observation: table}|nil
function M.runtime(protocol)
  local adapter = adapters[protocol]
  if not adapter then
    return nil
  end
  return {
    operations = require(adapter.operations),
    observation = require(adapter.observation),
  }
end

---@param connection OpencodeServer
---@return Promise<boolean>
function M.check_health(connection)
  local adapter = adapters[connection.protocol]
  if not adapter then
    return Promise.new():resolve(false)
  end

  local result = Promise.new()
  request(connection, adapter, 2000, function(response)
    result:resolve(
      response ~= nil and type(response.status) == 'number' and response.status >= 200 and response.status < 300
    )
  end, function()
    result:resolve(false)
  end)
  return result
end

return M
