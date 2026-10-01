local auth = require('opencode.auth')
local curl = require('opencode.curl')
local Promise = require('opencode.promise')

local M = {}

local methods = {
  GET = true,
  POST = true,
  PATCH = true,
  DELETE = true,
}

local function require_connection(connection)
  if type(connection) ~= 'table' or type(connection.is_ready) ~= 'function' or not connection:is_ready() then
    error('transport requires a ready Connection')
  end
end

local function require_request(request)
  if type(request) ~= 'table' or not methods[request.method] then
    error('transport request requires a supported method')
  end
  if type(request.path) ~= 'string' or request.path:sub(1, 1) ~= '/' or request.path:find('?', 1, true) then
    error('transport request requires a path without query parameters')
  end
  if request.body ~= nil and type(request.body) ~= 'string' then
    error('transport request body must be bytes')
  end
  if request.query ~= nil then
    if type(request.query) ~= 'string' or request.query == '' or request.query:sub(1, 1) == '?' then
      error('transport request query must be encoded bytes without a leading question mark')
    end
  end
end

local function request_url(connection, request)
  local url = connection.url:gsub('/$', '') .. request.path
  return request.query and (url .. '?' .. request.query) or url
end

local function request_headers(connection, has_body)
  local headers = auth.get_auth_headers(connection.credential)
  if has_body then
    headers = vim.tbl_extend('force', headers, { ['Content-Type'] = 'application/json' })
  end
  return headers
end

---@param connection OpencodeServer
---@param request {method: 'GET'|'POST'|'PATCH'|'DELETE', path: string, query?: string, body?: string}
---@return Promise<{status: integer, headers: table<string, string>, body: string}>
function M.request(connection, request)
  require_connection(connection)
  require_request(request)

  local result = Promise.new()
  local resource
  local completed = false
  local function finish(value, err)
    if completed then
      return
    end
    completed = true
    if resource then
      connection:_untrack_request(resource)
    end
    if err ~= nil then
      result:reject(err)
    else
      result:resolve(value)
    end
  end

  resource = curl.request({
    url = request_url(connection, request),
    method = request.method,
    headers = request_headers(connection, request.body ~= nil),
    body = request.body,
    proxy = '',
    callback = function(response)
      if
        type(response) ~= 'table'
        or type(response.status) ~= 'number'
        or type(response.body) ~= 'string'
        or (response.headers ~= nil and type(response.headers) ~= 'table')
      then
        finish(nil, 'invalid HTTP response')
        return
      end
      finish({
        status = response.status,
        headers = response.headers or {},
        body = response.body,
      })
    end,
    on_error = function(err)
      finish(nil, err)
    end,
    on_cancel = function()
      finish(nil, 'HTTP request cancelled')
    end,
  })
  if type(resource) ~= 'table' or type(resource.is_running) ~= 'function' or type(resource.shutdown) ~= 'function' then
    finish(nil, 'invalid HTTP request handle')
  elseif not completed then
    connection:_track_request(resource)
  end
  return result
end

---@param connection OpencodeServer
---@param request {method: 'GET'|'POST'|'PATCH'|'DELETE', path: string, query?: string, body?: string}
---@param on_chunk fun(chunk: string)
---@param on_disconnect? fun(reason: any)
---@return table
function M.stream(connection, request, on_chunk, on_disconnect)
  require_connection(connection)
  require_request(request)
  if type(on_chunk) ~= 'function' then
    error('transport stream requires a chunk callback')
  end

  local disconnected = false
  local resource
  local function disconnect(reason)
    if disconnected then
      return
    end
    disconnected = true
    if on_disconnect then
      on_disconnect(reason)
    end
  end

  resource = curl.request({
    url = request_url(connection, request),
    method = request.method,
    headers = request_headers(connection, request.body ~= nil),
    body = request.body,
    proxy = '',
    stream = vim.schedule_wrap(function(_, chunk)
      if type(chunk) == 'string' then
        on_chunk(chunk)
      end
    end),
    on_error = vim.schedule_wrap(function(err)
      local message = type(err) == 'table' and tostring(err.message or '') or tostring(err)
      if not message:match('exit_code=nil') then
        disconnect(err)
      end
    end),
    on_exit = vim.schedule_wrap(function(code, signal, shutdown_requested)
      if connection._stream == resource then
        connection:set_stream(nil)
      end
      if not shutdown_requested then
        disconnect({ code = code, signal = signal })
      end
    end),
  })
  connection:set_stream(resource)
  return resource
end

return M
