local state = require('opencode.state')
local curl = require('opencode.curl')
local Promise = require('opencode.promise')
local opencode_server = require('opencode.opencode_server')
local log = require('opencode.log')
local config = require('opencode.config')
local util = require('opencode.util')

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
  local promise = Promise.new()
  local runtime = config.runtime or {}
  local connection, connection_err = util.get_runtime_connection()

  if not connection then
    log.error(connection_err)
    vim.notify(connection_err, vim.log.levels.ERROR)
    return promise:reject(connection_err)
  end

  if state.opencode_server and state.opencode_server:is_running() then
    return promise:resolve(state.opencode_server)
  end

  state.opencode_server = opencode_server.new()
  local cwd = vim.fn.getcwd()
  local pre_start_command, pre_start_command_err = util.get_runtime_pre_start_command()

  if pre_start_command_err then
    log.error(pre_start_command_err)
    vim.notify(pre_start_command_err, vim.log.levels.ERROR)
    state.opencode_server = nil
    return promise:reject(pre_start_command_err)
  end

  local function continue_startup()
    if connection == 'remote' then
      local remote_url, remote_url_err = util.normalize_remote_url(runtime.remote_url)
      if not remote_url then
        local err = remote_url_err
        log.error(err)
        vim.notify(err, vim.log.levels.ERROR)
        state.opencode_server = nil
        return promise:reject(err)
      end

      state.opencode_server:connect(remote_url)

      M.call_api(state.opencode_server.url .. '/config', 'GET', nil)
        :and_then(function()
          promise:resolve(state.opencode_server)
        end)
        :catch(function(err)
          local err_msg = type(err) == 'string' and err or vim.inspect(err)
          log.error('Error connecting to remote opencode server: ' .. err_msg)
          vim.notify('Failed to connect to remote opencode server: ' .. err_msg, vim.log.levels.ERROR)
          state.opencode_server = nil
          promise:reject(err)
        end)

      return
    end

    state.opencode_server:spawn({
      cwd = cwd,
      on_ready = function(_, base_url)
        promise:resolve(state.opencode_server)
      end,
      on_error = function(err)
        local err_msg = type(err) == 'string' and err or vim.inspect(err)
        log.error('Error starting opencode server: ' .. err_msg)
        vim.notify('Failed to start opencode server: ' .. err_msg, vim.log.levels.ERROR)
        promise:reject(err)
      end,
      on_exit = function(exit_opts)
        promise:reject('Server exited')
      end,
    })
  end

  if pre_start_command then
    Promise.system(pre_start_command, { cwd = cwd }):and_then(function()
      continue_startup()
    end):catch(function(err)
      local err_msg = (type(err) == 'table' and (err.stderr or err.stdout)) or tostring(err)
      log.error('Error running runtime.pre_start_command: ' .. tostring(err_msg))
      vim.notify('Failed to run runtime.pre_start_command: ' .. tostring(err_msg), vim.log.levels.ERROR)
      state.opencode_server = nil
      promise:reject(err)
    end)
    return promise
  end

  continue_startup()

  return promise
end

return M
