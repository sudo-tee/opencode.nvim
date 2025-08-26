local Job = require('plenary.job')
local curl = require('plenary.curl')
local state = require('opencode.state')

local M = {}

--- Safely call a function if it exists.
--- @param fn function|nil
--- @param ... any
local function safe_call(fn, ...)
  local arg = { ... }
  return fn and vim.schedule(function()
    fn(unpack(arg))
  end)
end

local function cleanup_server_job()
  if state.opencode_server_job then
    pcall(function()
      state.opencode_server_job:shutdown()
    end)
    state.opencode_server_job = nil
  end
end

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

--- @class OpencodeServerSpawnOpts
--- @field cwd string
--- @field on_ready fun(job: any, url: string)
--- @field on_error fun(err: any)
--- @field on_exit fun(code: integer)

--- Spawn the opencode server as a background job.
--- @param opts OpencodeServerSpawnOpts
--- @return any job The spawned job object
function M.spawn_server(opts)
  opts = opts or {}
  local job = nil
  job = Job:new({
    command = 'opencode',
    args = { 'serve' },
    cwd = opts.cwd,
    on_stdout = function(_, data)
      local url = (data or ''):match('opencode server listening on ([^%s]+)')
      if url then
        safe_call(opts.on_ready, job, url)
      end
    end,
    on_stderr = function(_, data)
      if data then
        safe_call(opts.on_error, data)
      end
    end,
    on_exit = function(_, code)
      state.opencode_run_job = nil
      safe_call(opts.on_exit, code)
    end,
  })

  job:start()
  state.opencode_server_job = job
  return job
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
  }

  opts.body = body and vim.json.encode(body)

  curl.request(opts)
end

--- @class OpencodeServerRunOpts
--- @field cwd string
--- @field on_done fun(result: any)
--- @field on_error fun(err: any)
--- @field on_exit fun(err: any)
--- @field on_interrupt fun(err: any)

--- Run an opencode API call by spawning a server, making the call, and cleaning up.
--- @param endpoint string The API endpoint path (e.g. '/v1/foo')
--- @param method string|nil HTTP method
--- @param body table|nil Request body
--- @param opts OpencodeServerRunOpts
function M.run(endpoint, method, body, opts)
  opts = opts or {}

  state.opencode_server_job = M.spawn_server({
    cwd = opts.cwd,
    on_ready = function(_, base_url)
      local url = base_url and (base_url .. endpoint) or endpoint
      M.call_api(url, method, body, function(err, result)
        cleanup_server_job()
        if err then
          safe_call(opts.on_error, err)
        else
          safe_call(opts.on_done, result)
        end
      end)
    end,
    on_error = function(err)
      cleanup_server_job()
      safe_call(opts.on_error, err)
    end,
    on_exit = function(code)
      if code == nil then
        safe_call(opts.on_interrupt)
      elseif code and code ~= 0 then
        safe_call(opts.on_error, 'Server exited with code ' .. tostring(code))
      end
    end,
  })
  return state.opencode_server_job
end

return M
