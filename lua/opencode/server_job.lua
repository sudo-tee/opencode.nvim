local state = require('opencode.state')
local curl = require('opencode.curl')
local Promise = require('opencode.promise')
local opencode_server = require('opencode.opencode_server')
local log = require('opencode.log')
local config = require('opencode.config')

local M = {}
M.requests = {}

--- Normalize a URL by prepending http:// if no protocol is specified
--- @param url string The URL to normalize
--- @return string normalized_url The normalized URL
local function normalize_url(url)
  if not url:match('^https?://') then
    return 'http://' .. url
  end
  return url
end

--- URL encode a string for use in query parameters
--- @param str string The string to encode
--- @return string encoded_string The URL-encoded string
local function url_encode(str)
  if not str then return '' end
  str = string.gsub(str, '\n', '\r\n')
  str = string.gsub(str, '([^%w%-%.%_%~])', function(c)
    return string.format('%%%02X', string.byte(c))
  end)
  return str
end

--- Try to connect to an external opencode server by checking its health endpoint
--- @param base_url string The server base URL (host:port)
--- @param timeout number Timeout in seconds
--- @return Promise<string|nil> promise Resolves with base URL if successful, rejects if connection fails
local function try_external_server(base_url, timeout)
  local promise = Promise.new()
  
  -- Try multiple potential health check endpoints
  local health_endpoints = {
    '/global/health',  -- Standard endpoint for local spawned servers
    '/api/health',     -- Common API health endpoint
    '/health',         -- Simple health endpoint
  }
  
  local attempts = 0
  local last_error = nil
  
  local function try_next_endpoint()
    attempts = attempts + 1
    if attempts > #health_endpoints then
      promise:reject(last_error or 'All health check endpoints failed')
      return
    end
    
    local health_url = base_url .. health_endpoints[attempts]
    log.debug('try_external_server: checking health at %s (attempt %d/%d)', health_url, attempts, #health_endpoints)
    
    curl.request({
      url = health_url,
      method = 'GET',
      timeout = timeout * 1000, -- Convert to milliseconds
      callback = function(response)
        if response and response.status >= 200 and response.status < 300 then
          -- Check if response is JSON (not HTML from web UI)
          local is_json = response.body and (response.body:match('^%s*{') or response.body:match('^%s*%['))
          
          if is_json then
            local success, health_data = pcall(vim.json.decode, response.body)
            if success and health_data then
              log.debug('try_external_server: health check passed at %s', health_url)
              -- For external servers, return the base URL
              -- The directory query parameter in API calls will handle workspace routing
              promise:resolve(base_url)
              return
            end
          else
            log.debug('try_external_server: endpoint %s returned HTML, trying next', health_url)
          end
        else
          log.debug('try_external_server: endpoint %s returned status %d', health_url, response and response.status or 0)
        end
        
        last_error = string.format('Health check failed at %s', health_url)
        try_next_endpoint()
      end,
      on_error = function(err)
        log.debug('try_external_server: endpoint %s error: %s', health_url, vim.inspect(err))
        last_error = err
        try_next_endpoint()
      end,
    })
  end
  
  try_next_endpoint()
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
--- Tries to connect to an external server if configured, otherwise spawns a local server.
--- @return Promise<OpencodeServer> promise A promise that resolves with the server instance
function M.ensure_server()
  local promise = Promise.new()
  
  -- If server is already running, return it
  if state.opencode_server and state.opencode_server:is_running() then
    return promise:resolve(state.opencode_server)
  end

  -- Check if external server is configured
  local external_url = config.external_server_url
  local external_port = config.external_server_port
  
  if external_url and external_port then
    -- Normalize URL and construct full address
    local normalized_url = normalize_url(external_url)
    local base_url = string.format('%s:%d', normalized_url, external_port)
    local timeout = config.external_server_timeout or 5
    
    log.debug('ensure_server: trying external server at %s (timeout=%ds)', base_url, timeout)
    
    -- Try to connect to external server
    try_external_server(base_url, timeout):and_then(function(server_url)
      -- Successfully connected to external server
      log.debug('ensure_server: connected to external server at %s', server_url)
      state.opencode_server = opencode_server.from_external(server_url)
      promise:resolve(state.opencode_server)
    end):catch(function(err)
      -- Failed to connect to external server, fall back to local
      log.warn('ensure_server: failed to connect to external server: %s', vim.inspect(err))
      vim.notify(
        string.format('Failed to connect to external opencode server at %s. Falling back to local server.', base_url),
        vim.log.levels.WARN
      )
      
      -- Spawn local server as fallback
      M.spawn_local_server(promise)
    end)
  else
    -- No external server configured, spawn local server
    log.debug('ensure_server: no external server configured, spawning local server')
    M.spawn_local_server(promise)
  end

  return promise
end

--- Spawn a local opencode server
--- @param promise Promise<OpencodeServer> The promise to resolve/reject
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
