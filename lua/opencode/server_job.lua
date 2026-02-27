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

--- @return table<string, {directory: string, nvim_pids: number[], auto_kill: boolean, started_by_nvim: boolean}>
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

--- @param mappings table<string, {directory: string, nvim_pids: number[], auto_kill: boolean, started_by_nvim: boolean}>
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

--- Kill orphaned servers that have no connected clients
--- @param port number
--- @param started_by_nvim boolean
local function kill_orphaned_server(port, started_by_nvim)
  if not started_by_nvim then
    log.debug('clean_stale_pids: port %d server not started by nvim, skipping kill', port)
    return
  end

  local server_url = config.server.url or '127.0.0.1'
  local normalized_url = util.normalize_url_protocol(server_url)
  local base_url = string.format('%s:%d', normalized_url, port)
  local shutdown_url = base_url .. '/global/shutdown'
  
  log.info('clean_stale_pids: killing orphaned server at %s (no connected clients)', base_url)
  
  curl.request({
    url = shutdown_url,
    method = 'POST',
    timeout = 2000,
    proxy = '',
    callback = function(response)
      if response and response.status >= 200 and response.status < 300 then
        log.debug('clean_stale_pids: graceful shutdown successful for %s', base_url)
      else
        log.debug('clean_stale_pids: graceful shutdown failed for %s, will let OS clean up', base_url)
      end
    end,
    on_error = function(err)
      log.debug('clean_stale_pids: shutdown request failed for %s: %s', base_url, vim.inspect(err))
    end,
  })
end

--- Remove stale nvim PIDs from all port mappings and kill orphaned servers
local function clean_stale_pids()
  local mappings = load_port_mappings()
  local changed = false

  for port_key, mapping in pairs(mappings) do
    if mapping.nvim_pids then
      local active_pids = {}
      for _, pid_entry in ipairs(mapping.nvim_pids) do
        local pid = type(pid_entry) == 'number' and pid_entry or pid_entry.pid

        if vim.fn.getpid() == pid or vim.uv.kill(pid, 0) then
          if type(pid_entry) == 'number' then
            table.insert(active_pids, {
              pid = pid_entry,
              directory = mapping.directory,
            })
            changed = true
          else
            table.insert(active_pids, pid_entry)
          end
        else
          changed = true
        end
      end
      mapping.nvim_pids = active_pids
      
      if #active_pids == 0 then
        local port = tonumber(port_key)
        if port and mapping.started_by_nvim then
          kill_orphaned_server(port, mapping.started_by_nvim)
        end
        log.debug('clean_stale_pids: removing mapping for port %d (no connected clients)', port)
        mappings[port_key] = nil
        changed = true
      end
    end
  end

  if changed then
    save_port_mappings(mappings)
  end
end

--- @param port number
--- @param current_dir string
--- @return string|nil
local function check_port_mapping(port, current_dir)
  clean_stale_pids()
  local mappings = load_port_mappings()
  local port_key = tostring(port)
  local mapping = mappings[port_key]

  if mapping and mapping.directory and mapping.directory ~= current_dir then
    return mapping.directory
  end

  return nil
end

--- Find existing port for current directory in port mappings
--- @param current_dir string
--- @return number|nil port number if found, nil otherwise
local function find_existing_port_for_directory(current_dir)
  clean_stale_pids()
  local mappings = load_port_mappings()
  
  for port_key, mapping in pairs(mappings) do
    if mapping.directory == current_dir and mapping.nvim_pids and #mapping.nvim_pids > 0 then
      local port = tonumber(port_key)
      if port then
        return port
      end
    end
  end
  
  return nil
end

--- Find any existing server port (regardless of directory)
--- @return number|nil port number if found, nil otherwise
local function find_any_existing_port()
  clean_stale_pids()
  local mappings = load_port_mappings()
  
  for port_key, mapping in pairs(mappings) do
    if mapping.nvim_pids and #mapping.nvim_pids > 0 then
      local port = tonumber(port_key)
      if port then
        return port
      end
    end
  end
  
  return nil
end

--- Register port usage by this nvim instance
--- @param port number
--- @param directory string
--- @param started_by_nvim boolean
local function register_port_usage(port, directory, started_by_nvim)
  clean_stale_pids()
  local mappings = load_port_mappings()
  local port_key = tostring(port)
  local current_pid = vim.fn.getpid()
  local auto_kill = config.server.auto_kill

  if not mappings[port_key] then
    mappings[port_key] = {
      directory = directory,
      nvim_pids = {},
      auto_kill = auto_kill,
      started_by_nvim = started_by_nvim,
    }
  end

  local mapping = mappings[port_key]

  if not mapping.nvim_pids then
    mapping.nvim_pids = {}
  end
  if mapping.auto_kill == nil then
    mapping.auto_kill = auto_kill
  end
  if mapping.started_by_nvim == nil then
    mapping.started_by_nvim = started_by_nvim
  end

  local pid_exists = false
  local updated_pids = {}

  for _, pid_entry in ipairs(mapping.nvim_pids) do
    if type(pid_entry) == 'number' then
      local migrated_entry = {
        pid = pid_entry,
        directory = mapping.directory,
      }
      table.insert(updated_pids, migrated_entry)
      if pid_entry == current_pid then
        pid_exists = true
      end
    else
      table.insert(updated_pids, pid_entry)
      if pid_entry.pid == current_pid then
        pid_exists = true
      end
    end
  end

  mapping.nvim_pids = updated_pids

  if not pid_exists then
    table.insert(mapping.nvim_pids, {
      pid = current_pid,
      directory = directory,
    })
  end

  save_port_mappings(mappings)
  log.debug('register_port_usage: port=%d dir=%s nvim_pid=%d started_by_nvim=%s auto_kill=%s',
    port, directory, current_pid, tostring(started_by_nvim), tostring(auto_kill))
end

--- Unregister port usage by this nvim instance, killing server if last instance
--- @param port number|nil
M.unregister_port_usage = function(port)
  if not port then
    return
  end

  clean_stale_pids()
  local mappings = load_port_mappings()
  local port_key = tostring(port)
  local mapping = mappings[port_key]

  if not mapping then
    return
  end

  local current_pid = vim.fn.getpid()
  local new_pids = {}

  for _, pid_entry in ipairs(mapping.nvim_pids or {}) do
    local entry_pid = type(pid_entry) == 'number' and pid_entry or pid_entry.pid

    if entry_pid ~= current_pid then
      if type(pid_entry) == 'number' then
        table.insert(new_pids, {
          pid = pid_entry,
          directory = mapping.directory,
        })
      else
        table.insert(new_pids, pid_entry)
      end
    end
  end

  mapping.nvim_pids = new_pids

  local should_shutdown_server = #new_pids == 0 and mapping.started_by_nvim and mapping.auto_kill
  
  if should_shutdown_server and state.opencode_server then
    log.debug('unregister_port_usage: last nvim instance for port %d, shutting down server', port)
    state.opencode_server:shutdown()
  end

  if should_shutdown_server then
    mappings[port_key] = nil
  else
    log.debug('unregister_port_usage: port=%d still has %d nvim instance(s)', port, #new_pids)
  end

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
    proxy = '',  -- Disable proxy for health check
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
      --This means the job was killed, so we can ignore it
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

  local custom_port = config.server.port
  if custom_port == nil then
    custom_port = 4096
  elseif custom_port == 'auto' then
    if not config.server.spawn_command then
      local existing_port = find_any_existing_port()
      
      if existing_port then
        log.debug('ensure_server: found existing server on port %d, reusing for new directory', existing_port)
        custom_port = existing_port
      else
        log.debug('ensure_server: port=auto with no spawn_command, spawning new local server')
        M.spawn_local_server(promise, nil, custom_url)
        return promise
      end
    else
      local current_dir = vim.fn.getcwd()
      local existing_port = find_existing_port_for_directory(current_dir)
      
      if existing_port then
        custom_port = existing_port
        log.debug('ensure_server: found existing server for directory on port %d, reusing it', existing_port)
      else
        custom_port = math.random(1024, 65535)
        log.debug('ensure_server: using auto-generated port %d', custom_port)
      end
    end
  else
    log.debug('ensure_server: using configured port %d', custom_port)
  end

  local normalized_url = util.normalize_url_protocol(custom_url)
  local base_url = string.format('%s:%d', normalized_url, custom_port)
  local timeout = config.server.timeout or 5

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

    local mappings = load_port_mappings()
    local existing_started_by_nvim = false
    if mappings[tostring(custom_port)] then
      existing_started_by_nvim = mappings[tostring(custom_port)].started_by_nvim or false
    end
    
    register_port_usage(custom_port, current_dir, existing_started_by_nvim)

    state.opencode_server = opencode_server.from_custom(custom_server_url, custom_port)
    promise:resolve(state.opencode_server)
  end):catch(function(err)
    log.warn('try_connect_to_custom_server: failed to connect to custom server: %s', vim.inspect(err))

    if config.server.spawn_command and custom_port and custom_url then
      log.debug('try_connect_to_custom_server: server not running, executing server.spawn_command')
      vim.notify(
        string.format('[opencode.nvim] Custom server not found at %s, attempting to start it...', base_url),
        vim.log.levels.INFO
      )

      local ok, result = pcall(config.server.spawn_command, custom_port, custom_url)
      if not ok then
        log.error('try_connect_to_custom_server: server.spawn_command failed: %s', vim.inspect(result))
        vim.notify(
          string.format('[opencode.nvim] Failed to execute server.spawn_command: %s', tostring(result)),
          vim.log.levels.ERROR
        )
        promise:reject(string.format('Failed to spawn custom server on port %d', custom_port))
        return
      end

      local max_retries = 3
      local retry_count = 0

      local function retry_connection()
        retry_count = retry_count + 1
        local delay = retry_count * 2000 -- 2s, 4s, 6s

        log.debug('try_connect_to_custom_server: scheduling retry %d/%d after %dms', retry_count, max_retries, delay)

        vim.defer_fn(function()
          try_custom_server(base_url, timeout):and_then(function(custom_server_url)
            log.debug('try_connect_to_custom_server: connected to custom server after starting at %s (attempt %d)', custom_server_url, retry_count)
            register_port_usage(custom_port, vim.fn.getcwd(), true)
            state.opencode_server = opencode_server.from_custom(custom_server_url, custom_port)
            promise:resolve(state.opencode_server)
          end):catch(function(retry_err)
            if retry_count < max_retries then
              log.debug('try_connect_to_custom_server: retry %d failed, will retry again: %s', retry_count, vim.inspect(retry_err))
              retry_connection()
            else
              log.error('try_connect_to_custom_server: failed to connect after %d retries: %s', max_retries, vim.inspect(retry_err))
              if config.server.port == 'auto' then
                vim.notify(
                  string.format('[opencode.nvim] Failed to connect to custom opencode server at %s after starting. Falling back to local server.', base_url),
                  vim.log.levels.WARN
                )
                M.spawn_local_server(promise)
              else
                vim.notify(
                  string.format('[opencode.nvim] Failed to connect to custom opencode server at %s on port %d after starting.', base_url, custom_port),
                  vim.log.levels.ERROR
                )
                promise:reject(string.format('Failed to connect to custom server after spawning on port %d', custom_port))
              end
            end
          end)
        end, delay)
      end

      retry_connection()
    else
      log.debug('try_connect_to_custom_server: no spawn_command, falling back to local server with port=%s hostname=%s', custom_port, custom_url)
      vim.notify(
        string.format('[opencode.nvim] Custom server not found at %s on port %d. Starting local opencode server on this port...', base_url, custom_port),
        vim.log.levels.INFO
      )
      M.spawn_local_server(promise, custom_port, custom_url)
    end
  end)
end

--- @param promise Promise<OpencodeServer>
--- @param port? number|string Optional custom port
--- @param hostname? string Optional custom hostname
function M.spawn_local_server(promise, port, hostname)
  state.opencode_server = opencode_server.new()

  local spawn_opts = {
    on_ready = function(_, base_url)
      local url_port = base_url:match(':(%d+)')
      if url_port then
        local port_num = tonumber(url_port)
        state.opencode_server.port = port_num
        register_port_usage(port_num, vim.fn.getcwd(), true)
        log.debug('spawn_local_server: registered port %d for reference counting', port_num)
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
