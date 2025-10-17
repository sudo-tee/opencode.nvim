local state = require('opencode.state')
local curl = require('opencode.curl')
local Promise = require('opencode.promise')
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

M.requests = {}

function M.get_unresolved_requests()
  local unresolved = {}

  for _, data in ipairs(M.requests) do
    if data[2]._resolved ~= true then
      table.insert(unresolved, data)
    end
  end

  return unresolved
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
  local opts = {
    url = url,
    method = method or 'GET',
    headers = { ['Content-Type'] = 'application/json' },
    proxy = '',
    callback = function(response)
      handle_api_response(response, function(err, result)
        if err then
          local ok, pcall_err = pcall(call_promise.reject, call_promise, err)
          if not ok then
            vim.notify('Error while handling API error response: ' .. vim.inspect(pcall_err))
          end
          state.job_count = state.job_count - 1
        else
          local ok, pcall_err = pcall(call_promise.resolve, call_promise, result)
          if not ok then
            vim.notify('Error while handling API response: ' .. vim.inspect(pcall_err))
          end
          state.job_count = state.job_count - 1
        end
      end)
    end,
    on_error = function(err)
      local ok, pcall_err = pcall(call_promise.reject, call_promise, err)
      if not ok then
        vim.notify('Error while handling API on_error: ' .. vim.inspect(pcall_err))
      end
      state.job_count = state.job_count - 1
    end,
  }

  if body ~= nil then
    opts.body = body and vim.json.encode(body) or '{}'
  end

  -- FIXME: remove tracking code when thinking bug is fixed
  table.insert(M.requests, { opts, call_promise })

  curl.request(opts)
  return call_promise
end

--- Make a streaming HTTP API call to the opencode server.
--- @param url string The API endpoint URL
--- @param method string|nil HTTP method (default: 'GET')
--- @param body table|nil|boolean Request body (will be JSON encoded)
--- @param on_chunk fun(chunk: string) Callback invoked for each chunk of data received
--- @return Job job The underlying job instance
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

  return curl.request(opts)
end

function M.ensure_server()
  if state.opencode_server_job and state.opencode_server_job:is_running() then
    return state.opencode_server_job
  end

  local promise = Promise.new()
  state.opencode_server_job = opencode_server.new()

  state.opencode_server_job:spawn({
    on_ready = function(_, base_url)
      promise:resolve(state.opencode_server_job)
    end,
    on_error = function(err)
      promise:reject(err)
    end,
    on_exit = function(exit_opts)
      state.opencode_server_job:shutdown()
    end,
  })

  return promise:wait()
end

return M
