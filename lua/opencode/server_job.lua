local state = require('opencode.state')
local curl = require('opencode.curl')
local Promise = require('opencode.promise')
local opencode_server = require('opencode.opencode_server')
local config = require('opencode.config')

local M = {}
M.requests = {}

local DEFAULT_PORT = 41096

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
--- @generic T
--- @param url string The API endpoint URL
--- @param method string|nil HTTP method (default: 'GET')
--- @param body table|nil|boolean Request body (will be JSON encoded)
--- @return Promise<T> promise A promise that resolves with the result or rejects with an error
function M.call_api(url, method, body)
  local call_promise = Promise.new()

  state.job_count = state.job_count + 1

  local request_entry = { nil, call_promise }
  table.insert(M.requests, request_entry)

  -- Remove completed promises from list, update job_count
  local function remove_from_requests()
    for i, entry in ipairs(M.requests) do
      if entry == request_entry then
        table.remove(M.requests, i)
        break
      end
    end
    state.job_count = #M.requests
  end

  local opts = {
    url = url,
    method = method or 'GET',
    headers = { ['Content-Type'] = 'application/json' },
    proxy = '',
    callback = function(response)
      remove_from_requests()
      handle_api_response(response, function(err, result)
        if err then
          local ok, pcall_err = pcall(function()
            call_promise:reject(err)
          end)
          if not ok then
            vim.schedule(function()
              vim.notify('Error while handling API error response: ' .. vim.inspect(pcall_err))
            end)
          end
        else
          local ok, pcall_err = pcall(function()
            call_promise:resolve(result)
          end)
          if not ok then
            vim.schedule(function()
              vim.notify('Error while handling API response: ' .. vim.inspect(pcall_err))
            end)
          end
        end
      end)
    end,
    on_error = function(err)
      remove_from_requests()
      local ok, pcall_err = pcall(function()
        call_promise:reject(err)
      end)
      if not ok then
        vim.schedule(function()
          vim.notify('Error while handling API on_error: ' .. vim.inspect(pcall_err))
        end)
      end
    end,
  }

  if body ~= nil then
    opts.body = body and vim.json.encode(body) or '{}'
  end

  -- add opts to request_entry for request tracking
  request_entry[1] = opts

  curl.request(opts)
  return call_promise
end

--- Make a streaming HTTP API call to the opencode server.
--- @param url string The API endpoint URL
--- @param method string|nil HTTP method (default: 'GET')
--- @param body table|nil|boolean Request body (will be JSON encoded)
--- @param on_chunk fun(chunk: string) Callback invoked for each chunk of data received
--- @return table The underlying job instance
function M.stream_api(url, method, body, on_chunk)
  local opts = {
    url = url,
    method = method or 'GET',
    proxy = '',
    stream = function(err, chunk)
      on_chunk(chunk)
    end,
    on_error = function(err)
      --This means the job was killed, so we can ignore it
      if err.message:match('exit_code=nil') then
        return
      end
      vim.notify('Error in streaming request: ' .. vim.inspect(err), vim.log.levels.ERROR)
    end,
    on_exit = function(code, signal)
      if code ~= 0 then
        vim.notify('Streaming request exited with code ' .. tostring(code), vim.log.levels.WARN)
      end
    end,
  }

  if body ~= nil then
    opts.body = body and vim.json.encode(body) or '{}'
  end

  return curl.request(opts) --[[@as table]]
end

--- Ensure the opencode server is running, starting it if necessary.
--- @return Promise<OpencodeServer> promise A promise that resolves with the server instance
function M.ensure_server()
  local port = config.server and config.server.port or DEFAULT_PORT
  local server_url = 'http://127.0.0.1:' .. port

  local promise = Promise.new()

  -- Fast path: check in-memory server instance
  if state.opencode_server and state.opencode_server:is_running() then
    return promise:resolve(state.opencode_server)
  end

  -- Step 1: Health check to see if server already exists
  local api_client = require('opencode.api_client')
  local ok, is_healthy = pcall(function()
    return api_client.check_health(server_url, 2000):wait(2500)
  end)

  if ok and is_healthy then
    state.opencode_server = opencode_server.from_existing(server_url)
    return promise:resolve(state.opencode_server)
  end

  -- Step 2: Try to start the server (port binding is atomic mutex)
  state.opencode_server = opencode_server.new()

  state.opencode_server:spawn({
    port = port,
    on_ready = function(_, base_url)
      promise:resolve(state.opencode_server)
    end,
    on_error = function(err)
      -- Retry health check (another instance may have just started successfully)
      vim.defer_fn(function()
        local retry_ok, retry_healthy = pcall(function()
          return api_client.check_health(server_url, 2000):wait(2500)
        end)
        if retry_ok and retry_healthy then
          state.opencode_server = opencode_server.from_existing(server_url)
          promise:resolve(state.opencode_server)
        else
          -- Check if port is occupied by another application
          local err_msg = tostring(err)
          if err_msg:match('address already in use') or err_msg:match('EADDRINUSE') then
            promise:reject(string.format(
              "Port %d is occupied by another application. "
                .. "Configure a different port via require('opencode').setup({ server = { port = XXXX } })",
              port
            ))
          else
            promise:reject(err)
          end
        end
      end, 500)
    end,
    on_exit = function(exit_opts)
      promise:reject('Server exited')
    end,
  })

  return promise
end

return M
