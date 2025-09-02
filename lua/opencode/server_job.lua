local util = require('opencode.util')
local safe_call = util.safe_call
local curl = require('plenary.curl')
local opencode_server = require('opencode.opencode_server')

local M = {}

--- @param response {status: integer, body: string}
--- @param cb fun(err: any, result: any)
local function handle_api_response(response, cb)
  local success, json_body = pcall(vim.json.decode, response.body)

  if response.status >= 200 and response.status < 300 then
    cb(nil, success and json_body or response.body)
  else
    cb(success and json_body or response.body, nil)
  end
end

--- Make an HTTP API call to the opencode server.
--- @param url string The API endpoint URL
--- @param method string|nil HTTP method (default: 'GET')
--- @param body table|nil Request body (will be JSON encoded)
--- @param cb fun(err: any, result: any) Callback for response
function M.call_api(url, method, body, cb)
  local opts = {
    url = url,
    method = method or 'GET',
    headers = { ['Content-Type'] = 'application/json' },
    proxy = '',
    callback = function(response)
      handle_api_response(response, cb)
    end,
    on_error = function(err)
      cb(err, nil)
    end,
  }

  if body then
    opts.body = body and vim.json.encode(body)
  end

  curl.request(opts)
end

--- @class OpencodeServerRunOpts
--- @field cwd string
--- @field on_ready fun(job: any, url: string)
--- @field on_done fun(result: any)
--- @field on_error fun(err: any)
--- @field on_exit fun(err: any)
--- @field on_interrupt fun(err: any)

--- Run an opencode API call by spawning a server, making the call, and cleaning up.
--- @param endpoint string The API endpoint path (e.g. '/v1/foo')
--- @param method string|nil HTTP method
--- @param body table|nil Request body
--- @param opts OpencodeServerRunOpts
--- @return OpencodeServer server_job The server job instance
function M.run(endpoint, method, body, opts)
  opts = opts or {}

  return M.with_server(function(server_job, base_url)
    local url = base_url .. endpoint
    M.call_api(url, method, body, function(err, result)
      if err then
        safe_call(opts.on_error, err)
      else
        safe_call(opts.on_done, result)
      end
      server_job:shutdown()
    end)
  end, opts)
end

--- Spawn an opencode server, and invoke a callback when it's ready.
--- @param cb fun(job: OpencodeServer, url: string)
--- @param opts OpencodeServerRunOpts
--- @return OpencodeServer server_job The server job instance
function M.with_server(cb, opts)
  opts = opts or {}
  local server_job = opencode_server.new()

  server_job:spawn({
    cwd = opts.cwd,
    on_ready = function(_, base_url)
      safe_call(cb, server_job, base_url)
    end,
    on_error = function(err)
      server_job:shutdown()
      safe_call(opts.on_error, err)
    end,
    on_exit = function(code)
      if code == nil then
        safe_call(opts.on_interrupt)
      elseif code and code ~= 0 then
        safe_call(opts.on_error, 'Server exited with code ' .. tostring(code))
      end
      server_job:shutdown()
    end,
  })

  return server_job
end

return M
