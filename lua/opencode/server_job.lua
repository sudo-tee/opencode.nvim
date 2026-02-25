local state = require('opencode.state')
local curl = require('opencode.curl')
local Promise = require('opencode.promise')
local opencode_server = require('opencode.opencode_server')
local log = require('opencode.log')
local config = require('opencode.config')
local util = require('opencode.util')

local M = {}
M.requests = {}

--- @return string
local function get_port_mapping_file()
  local data_dir = vim.fn.stdpath('data')
  return data_dir .. '/opencode_port_mappings.json'
end

--- @return table<string, string>
local function load_port_mappings()
  local file_path = get_port_mapping_file()
  local file = io.open(file_path, 'r')
  if not file then
    return {}
  end
  
  local content = file:read('*all')
  file:close()
  
  if not content or content == '' then
    return {}
  end
  
  local success, mappings = pcall(vim.json.decode, content)
  return success and mappings or {}
end

--- @param mappings table<string, string>
local function save_port_mappings(mappings)
  local file_path = get_port_mapping_file()
  local file = io.open(file_path, 'w')
  if not file then
    log.warn('Failed to open port mappings file for writing: %s', file_path)
    return
  end
  
  file:write(vim.json.encode(mappings))
  file:close()
end

--- @param port number
--- @param current_dir string
--- @return string|nil
local function check_port_mapping(port, current_dir)
  local mappings = load_port_mappings()
  local port_key = tostring(port)
  local mapped_dir = mappings[port_key]
  
  if mapped_dir and mapped_dir ~= current_dir then
    return mapped_dir
  end
  
  return nil
end

--- @param port number
--- @param directory string
local function register_port_mapping(port, directory)
  local mappings = load_port_mappings()
  mappings[tostring(port)] = directory
  save_port_mappings(mappings)
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
    callback = function(response)
      if response and response.status >= 200 and response.status < 300 then
        local success, health_data = pcall(vim.json.decode, response.body)
        if success and health_data then
          log.debug('try_custom_server: health check passed')
          promise:resolve(base_url)
          return
        end
      end
      
      local err_msg = string.format('Health check failed at %s (status: %d)', health_url, response and response.status or 0)
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
--- @return Promise<OpencodeServer>
function M.ensure_server()
  local promise = Promise.new()

  if state.opencode_server and state.opencode_server:is_running() then
    return promise:resolve(state.opencode_server)
  end

  if not config.custom_server_enabled then
    log.debug('ensure_server: custom server not enabled, spawning local server')
    M.spawn_local_server(promise)
    return promise
  end

  local custom_url = config.custom_server_url
  if not custom_url then
    log.error('ensure_server: custom_server_enabled is true but custom_server_url is not set')
    vim.notify(
      'Custom server enabled but custom_server_url is not configured',
      vim.log.levels.ERROR
    )
    promise:reject('custom_server_url is required when custom_server_enabled is true')
    return promise
  end

  local custom_port = config.custom_server_port
  if custom_port == nil then
    custom_port = 4096
  elseif custom_port == 'auto' then
    custom_port = math.random(1024, 65535)
    log.debug('ensure_server: using auto-generated port %d', custom_port)
  end

  local normalized_url = util.normalize_url_protocol(custom_url)
  local base_url = string.format('%s:%d', normalized_url, custom_port)
  local timeout = config.custom_server_timeout or 5

  log.debug('ensure_server: trying custom server at %s (timeout=%ds)', base_url, timeout)

  M.try_connect_to_custom_server(base_url, timeout, promise, custom_port, custom_url)

  return promise
end

--- @param base_url string
--- @param timeout number
--- @param promise Promise<OpencodeServer>
--- @param custom_port number|nil
--- @param custom_url string|nil
function M.try_connect_to_custom_server(base_url, timeout, promise, custom_port, custom_url)
  try_custom_server(base_url, timeout):and_then(function(custom_server_url)
    log.debug('try_connect_to_custom_server: connected to custom server at %s', custom_server_url)
    
    local current_dir = vim.fn.getcwd()
    local mapped_dir = check_port_mapping(custom_port, current_dir)
    
    if mapped_dir then
      log.warn('try_connect_to_custom_server: port %d is already mapped to directory %s but current directory is %s', 
        custom_port, mapped_dir, current_dir)
      
      vim.notify(
        string.format(
          'Warning: OpenCode server at %s (port %d) is already serving a different directory:\n' ..
          'Server directory: %s\n' ..
          'Current directory: %s\n\n' ..
          'To run isolated servers per project, configure custom_server_port = "auto" in your config.',
          base_url, custom_port, mapped_dir, current_dir
        ),
        vim.log.levels.WARN
      )
    else
      register_port_mapping(custom_port, current_dir)
    end
    
    state.opencode_server = opencode_server.from_custom(custom_server_url)
    promise:resolve(state.opencode_server)
  end):catch(function(err)
    log.warn('try_connect_to_custom_server: failed to connect to custom server: %s', vim.inspect(err))
    
    if config.custom_server_command and custom_port and custom_url then
      log.debug('try_connect_to_custom_server: server not running, executing custom_server_command')
      vim.notify(
        string.format('Custom server not found at %s, attempting to start it...', base_url),
        vim.log.levels.INFO
      )
      
      local ok, result = pcall(config.custom_server_command, custom_port, custom_url)
      if not ok then
        log.error('try_connect_to_custom_server: custom_server_command failed: %s', vim.inspect(result))
        vim.notify(
          string.format('Failed to execute custom_server_command: %s', tostring(result)),
          vim.log.levels.ERROR
        )
        M.spawn_local_server(promise)
        return
      end
      
      vim.defer_fn(function()
        try_custom_server(base_url, timeout):and_then(function(custom_server_url)
          log.debug('try_connect_to_custom_server: connected to custom server after starting at %s', custom_server_url)
          register_port_mapping(custom_port, vim.fn.getcwd())
          state.opencode_server = opencode_server.from_custom(custom_server_url)
          promise:resolve(state.opencode_server)
        end):catch(function(retry_err)
          log.error('try_connect_to_custom_server: failed to connect after starting server: %s', vim.inspect(retry_err))
          vim.notify(
            string.format('Failed to connect to custom opencode server at %s after starting. Falling back to local server.', base_url),
            vim.log.levels.WARN
          )
          M.spawn_local_server(promise)
        end)
      end, 2000)
    else
      vim.notify(
        string.format('Failed to connect to custom opencode server at %s. Falling back to local server.', base_url),
        vim.log.levels.WARN
      )
      M.spawn_local_server(promise)
    end
  end)
end

--- @param promise Promise<OpencodeServer>
function M.spawn_local_server(promise)
  state.opencode_server = opencode_server.new()

  state.opencode_server:spawn({
    on_ready = function(_, base_url)
      promise:resolve(state.opencode_server)
    end,
    on_error = function(err)
      log.error('Error starting opencode server: ' .. vim.inspect(err))
      vim.notify('Failed to start opencode server', vim.log.levels.ERROR)
      promise:reject(err)
    end,
    on_exit = function(exit_opts)
      promise:reject('Server exited')
    end,
  })
end

return M
