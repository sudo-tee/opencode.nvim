local state = require('opencode.state')
local curl = require('opencode.curl')
local Promise = require('opencode.promise')
local opencode_server = require('opencode.opencode_server')
local port_mapping = require('opencode.port_mapping')
local log = require('opencode.log')
local config = require('opencode.config')
local util = require('opencode.util')

local M = {}
M.requests = {}

--- Wrapper for port_mapping.unregister to maintain backward compatibility
--- @param port number|nil
function M.unregister_port_usage(port)
  port_mapping.unregister(port, state.opencode_server)
end

--- @param base_url string
--- @param timeout number
--- @return Promise<string|nil>
local function try_custom_server(base_url, timeout)
  local promise = Promise.new()
  local health_url = base_url .. '/global/health'

  log.debug('try_custom_server: checking health at %s', health_url)

  curl.request({
    url = health_url,
    method = 'GET',
    timeout = timeout * 1000,
    proxy = '', -- Disable proxy for health check
    callback = function(response)
      if response and response.status >= 200 and response.status < 300 then
        local success, health_data = pcall(vim.json.decode, response.body)
        if success and health_data then
          log.debug('try_custom_server: health check passed')
          promise:resolve(base_url)
          return
        end
      end

      local err_msg =
        string.format('Health check failed at %s (status: %d)', health_url, response and response.status or 0)
      log.debug('try_custom_server: %s', err_msg)
      promise:reject(err_msg)
    end,
    on_error = function(err)
      log.debug('try_custom_server: error connecting to %s: %s', health_url, vim.inspect(err))
      promise:reject(err)
    end,
  })

  return promise
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
              vim.notify('[opencode.nvim] Error while handling API error response: ' .. vim.inspect(pcall_err))
            end)
          end
        else
          local ok, pcall_err = pcall(function()
            call_promise:resolve(result)
          end)
          if not ok then
            vim.schedule(function()
              vim.notify('[opencode.nvim] Error while handling API response: ' .. vim.inspect(pcall_err))
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
          vim.notify('[opencode.nvim] Error while handling API on_error: ' .. vim.inspect(pcall_err))
        end)
      end
    end,
  }

  if body ~= nil then
    opts.body = body and vim.json.encode(body) or '{}'
  end

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
      if err.message:match('exit_code=nil') then
        return
      end
      vim.schedule(function()
        vim.notify('[opencode.nvim] Error in streaming request: ' .. vim.inspect(err), vim.log.levels.ERROR)
      end)
    end,
    on_exit = function(code, signal)
      if code ~= 0 then
        vim.schedule(function()
          vim.notify('[opencode.nvim] Streaming request exited with code ' .. tostring(code), vim.log.levels.WARN)
        end)
      end
    end,
  }

  if body ~= nil then
    opts.body = body and vim.json.encode(body) or '{}'
  end

  return curl.request(opts) --[[@as table]]
end

--- @param custom_url string
--- @return number|nil port, or nil if we should spawn local instead
local function resolve_port(custom_url)
  local custom_port = config.server.port or 'auto'
  if custom_port ~= 'auto' then
    return custom_port
  end

  if not config.server.spawn_command then
    return port_mapping.find_any_existing_port()
  end

  local existing = port_mapping.find_port_for_directory(vim.fn.getcwd())
  return existing or math.random(1024, 65535)
end

--- Ensure the opencode server is running, starting it if necessary.
--- @return Promise<OpencodeServer>
function M.ensure_server()
  local promise = Promise.new()

  if state.opencode_server and state.opencode_server:is_running() then
    return promise:resolve(state.opencode_server)
  end

  local custom_url = config.server.url
  if not custom_url then
    log.debug('ensure_server: server.url not configured, spawning local server')
    M.spawn_local_server(promise)
    return promise
  end

  local custom_port = resolve_port(custom_url)
  local base_url = string.format('%s:%d', util.normalize_url_protocol(custom_url), custom_port)

  local timeout = config.server.timeout or 5

  log.debug('ensure_server: trying custom server at %s (timeout=%ds)', base_url, timeout)

  M.try_connect_to_custom_server(base_url, timeout, promise, custom_port, custom_url)

  return promise
end

local function retry_connect(base_url, timeout, max_retries, on_success, on_failure)
  local function attempt(retry_count)
    vim.defer_fn(function()
      try_custom_server(base_url, timeout):and_then(on_success):catch(function(err)
        if retry_count < max_retries then
          attempt(retry_count + 1)
        else
          log.error('try_connect_to_custom_server: exhausted %d retries: %s', max_retries, vim.inspect(err))
          on_failure(err)
        end
      end)
    end, retry_count * 2000)
  end
  attempt(1)
end

local function spawn_and_retry(base_url, custom_port, custom_url, promise, timeout)
  local ok, result = pcall(config.server.spawn_command, custom_port, custom_url)
  if not ok then
    log.error('spawn_command failed: %s', vim.inspect(result))
    promise:reject(string.format('Failed to spawn custom server on port %d', custom_port))
    return
  end

  local server_pid = type(result) == 'number' and result or nil

  retry_connect(base_url, timeout, 3, function(url)
    port_mapping.register(custom_port, vim.fn.getcwd(), true, 'custom', url, server_pid)
    state.opencode_server = opencode_server.from_custom(url, custom_port)
    promise:resolve(state.opencode_server)
  end, function(_err)
    if config.server.port == 'auto' then
      log.notify('Failed to connect after spawning, falling back to local server', vim.log.levels.WARN)
      M.spawn_local_server(promise, custom_port, custom_url)
    else
      promise:reject(string.format('Failed to connect to custom server after spawning on port %d', custom_port))
    end
  end)
end

function M.try_connect_to_custom_server(base_url, timeout, promise, custom_port, custom_url)
  try_custom_server(base_url, timeout)
    :and_then(function(url)
      local existing_started_by_nvim = port_mapping.started_by_nvim(custom_port)
      port_mapping.register(custom_port, vim.fn.getcwd(), existing_started_by_nvim, 'custom', url, nil)
      state.opencode_server = opencode_server.from_custom(url, custom_port)
      log.notify(
        string.format('Connected to remote server at %s on port %d.', base_url, custom_port),
        vim.log.levels.INFO
      )
      promise:resolve(state.opencode_server)
    end)
    :catch(function(err)
      log.warn('failed to connect to %s: %s', base_url, vim.inspect(err))
      if config.server.spawn_command and custom_port and custom_url then
        spawn_and_retry(base_url, custom_port, custom_url, promise, timeout)
      else
        M.spawn_local_server(promise, custom_port, custom_url)
      end
    end)
end

--- @param promise Promise<OpencodeServer>
--- @param port? number|string Optional custom port
--- @param hostname? string Optional custom hostname
function M.spawn_local_server(promise, port, hostname)
  state.opencode_server = opencode_server.new()
  log.notify(string.format('Starting local server at %s on port %d.', hostname, port), vim.log.levels.INFO)

  local spawn_opts = {
    on_ready = function(job, base_url)
      local url_port = base_url:match(':(%d+)')
      if url_port then
        local port_num = tonumber(url_port)
        state.opencode_server.port = port_num
        local server_pid = job and job.pid
        port_mapping.register(port_num, vim.fn.getcwd(), true, 'serve', nil, server_pid)
        log.debug(
          'spawn_local_server: registered port %d for reference counting (server_pid=%s)',
          port_num,
          tostring(server_pid)
        )
      end
      promise:resolve(state.opencode_server)
    end,
    on_error = function(err)
      log.error('Error starting opencode server: ' .. vim.inspect(err))
      vim.schedule(function()
        vim.notify('[opencode.nvim] Failed to start opencode server', vim.log.levels.ERROR)
      end)
      promise:reject(err)
    end,
    on_exit = function(exit_opts)
      promise:reject('Server exited')
    end,
  }

  if port then
    spawn_opts.port = port
  end
  if hostname then
    spawn_opts.hostname = hostname
  end

  state.opencode_server:spawn(spawn_opts)
end

return M
