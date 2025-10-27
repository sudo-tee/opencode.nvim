local state = require('opencode.state')
local curl = require('opencode.curl')
local Promise = require('opencode.promise')
local opencode_server = require('opencode.opencode_server')

local M = {}
M.requests = {}

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
            vim.schedule(function()
              vim.notify('Error while handling API error response: ' .. vim.inspect(pcall_err))
            end)
          end
        else
          local ok, pcall_err = pcall(call_promise.resolve, call_promise, result)
          if not ok then
            vim.schedule(function()
              vim.notify('Error while handling API response: ' .. vim.inspect(pcall_err))
            end)
          end
        end
      end)
    end,
    on_error = function(err)
      local ok, pcall_err = pcall(call_promise.reject, call_promise, err)
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

  local request_entry = { opts, call_promise }
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

  call_promise:and_then(function(result)
    remove_from_requests()
    return result
  end)

  call_promise:catch(function(err)
    remove_from_requests()
    error(err)
  end)

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
  if state.opencode_server and state.opencode_server:is_running() then
    return state.opencode_server
  end

  local promise = Promise.new()
  state.opencode_server = opencode_server.new()

  state.opencode_server:spawn({
    on_ready = function(_, base_url)
      promise:resolve(state.opencode_server)
    end,
    on_error = function(err)
      promise:reject(err)
    end,
    on_exit = function(exit_opts)
      promise:reject('Server exited')
    end,
  })

  return promise:wait()
end

return M
