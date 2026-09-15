local state = require('opencode.state')
local Promise = require('opencode.promise')
local opencode_server = require('opencode.opencode_server')
local port_mapping = require('opencode.port_mapping')
local log = require('opencode.log')
local config = require('opencode.config')
local util = require('opencode.util')
local auth = require('opencode.auth')

local M = {}
local generate_spawn_password

local function non_empty(value)
  return type(value) == 'string' and value ~= '' and value or nil
end

local function password_file_path()
  local path = config.server.password_file
  if path == nil or path == '' then
    return nil
  end
  if type(path) ~= 'string' then
    error('server.password_file must be a string')
  end
  return path
end

local function read_saved_password()
  local path = password_file_path()
  if not path then
    return nil
  end
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return nil
  end
  if stat.type ~= 'file' or vim.fn.filereadable(path) ~= 1 then
    error('server.password_file is not a readable file: ' .. path)
  end
  local permissions = vim.fn.getfperm(path)
  if type(permissions) ~= 'string' or #permissions < 9 or permissions:sub(4, 9) ~= '------' then
    error('server.password_file must be accessible only by its owner: ' .. path)
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    error('failed to read server.password_file: ' .. path)
  end
  local password = lines[1]
  if not non_empty(password) then
    error('server.password_file is empty: ' .. path)
  end
  return password
end

local function save_password(password)
  local path = password_file_path()
  if not path then
    return password
  end
  local ok, result = pcall(vim.fn.mkdir, vim.fn.fnamemodify(path, ':h'), 'p')
  if not ok or result == -1 then
    error('failed to create server.password_file directory: ' .. path)
  end

  local fd, open_error = vim.uv.fs_open(path, 'wx', 384)
  if not fd then
    if vim.uv.fs_stat(path) then
      return read_saved_password()
    end
    error('failed to create server.password_file: ' .. tostring(open_error))
  end
  local payload = password .. '\n'
  local written, write_error = vim.uv.fs_write(fd, payload, -1)
  local synced, sync_error = vim.uv.fs_fsync(fd)
  vim.uv.fs_close(fd)
  if written ~= #payload or not synced then
    error('failed to persist server.password_file: ' .. tostring(write_error or sync_error))
  end
  if vim.fn.setfperm(path, 'rw-------') ~= 1 then
    error('failed to set server.password_file permissions: ' .. path)
  end
  return read_saved_password()
end

local function resolve_config_value(name)
  local value = config.server[name]
  if type(value) == 'function' then
    local ok, resolved = pcall(value)
    if not ok then
      error(string.format('server.%s failed: %s', name, tostring(resolved)))
    end
    value = resolved
  end
  if value == nil or value == '' then
    return nil
  end
  if type(value) ~= 'string' then
    error(string.format('server.%s must resolve to a string', name))
  end
  return value
end

local function resolve_credential(generate_password)
  local configured_password = resolve_config_value('password')
  local password = configured_password
  if not password then
    password = read_saved_password()
  end
  password = password or non_empty(vim.env.OPENCODE_PASSWORD) or non_empty(vim.env.OPENCODE_SERVER_PASSWORD)
  if not password and generate_password then
    password = generate_spawn_password()
  end
  if generate_password and password and password_file_path() and not vim.uv.fs_stat(password_file_path()) then
    password = save_password(password)
  end

  return {
    username = resolve_config_value('username') or non_empty(vim.env.OPENCODE_SERVER_USERNAME) or 'opencode',
    password = password,
  }
end

local function apply_probe(server, probe, acquired_pid)
  server.protocol = probe.protocol
  server.server_identity = {
    version = probe.response.version,
    pid = probe.response.pid or acquired_pid,
  }
  server.version = server.server_identity.version
  return server
end

generate_spawn_password = function()
  local seed = tostring(vim.uv.hrtime()) .. tostring(math.random())
  return vim.fn.sha256(seed):sub(1, 32)
end

local function try_custom_server(server, timeout)
  local probe = server:probe_connection(timeout * 1000)
  return probe:and_then(function(probe_result)
    return apply_probe(server, probe_result, server.custom_pid or (server.job and server.job.pid))
  end)
end

--- @return number|nil port, or nil if we should spawn local instead
local function resolve_port()
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

-- CLI capability selects the launcher only; authenticated health selects the protocol.
local try_native_service = Promise.async(function()
  local timeout = (config.server.timeout or 5) * 1000
  local function command(...)
    local args = { config.opencode_executable, ... }
    local ok, result = pcall(function()
      return Promise.system(args, { text = true, timeout = timeout }):await()
    end)
    if not ok then
      -- In particular, never include the password command's stdout in an error.
      error('OpenCode command failed: ' .. table.concat(args, ' '), 0)
    end
    return vim.trim(result.stdout or '')
  end

  local help = command('--help')
  if help == '' then
    error('OpenCode returned empty command help', 0)
  end
  if not help:match('\n%s*service%s+') then
    return nil
  end

  local url = command('service', 'status')
  if url == 'stopped' then
    url = command('service', 'start')
  end
  if not url:match('^https?://[^%s]+$') then
    error('OpenCode service did not return an HTTP endpoint', 0)
  end
  local password = command('service', 'get', 'password')
  if password == '' then
    error('OpenCode service did not return a credential', 0)
  end
  local server = opencode_server.from_custom(url)
  server.credential = { username = 'opencode', password = password }
  local probe = server:probe_connection(timeout):await()
  if probe.protocol ~= 'v2' then
    error('OpenCode background service did not provide V2 health', 0)
  end
  apply_probe(server, probe)
  server:mark_ready()
  -- The native service owns its lifecycle and never enters plugin port bookkeeping.
  state.jobs.set_server(server)
  return server
end)

local function _start_server()
  local promise = Promise.new()

  local custom_url = config.server.url
  if not custom_url then
    if config.server.spawn_command then
      M.spawn_local_server(promise)
      return promise
    end
    try_native_service()
      :and_then(function(server)
        if server then
          promise:resolve(server)
        else
          M.spawn_local_server(promise)
        end
      end)
      :catch(function(err)
        promise:reject(err)
      end)
    return promise
  end

  local custom_port = resolve_port(custom_url)
  if not custom_port then
    M.spawn_local_server(promise)
    return promise
  end

  local base_url = string.format('%s:%d', util.normalize_url_protocol(custom_url), custom_port)

  local timeout = config.server.timeout or 5

  log.debug('ensure_server: trying custom server at %s (timeout=%ds)', base_url, timeout)

  M.try_connect_to_custom_server(base_url, timeout, promise, custom_port, custom_url)

  return promise
end

local pending_connection

---Ensure all callers share startup and health checks until the server is ready.
---@return Promise<OpencodeServer>
function M.ensure_server()
  if pending_connection then
    return pending_connection
  end

  local connection = Promise.new()
  pending_connection = connection
  Promise.spawn(function()
    while true do
      local server = state.opencode_server
      if not server or not server:is_ready() then
        return _start_server():await()
      end
      local ok, healthy = pcall(function()
        return server:check_health():await()
      end)
      if state.opencode_server == server then
        if ok and healthy then
          return server
        end
        local reconnectable = not ok
          and type(healthy) == 'table'
          and (healthy.kind == 'transport' or healthy.kind == 'identity_changed')
        if reconnectable or (ok and not healthy) then
          log.warn('ensure_server: cached server unavailable or replaced, reconnecting')
          state.jobs.clear_server()
          return _start_server():await()
        end
        error(healthy, 0)
      end
    end
  end)
    :and_then(function(server)
      pending_connection = nil
      connection:resolve(server)
    end)
    :catch(function(err)
      pending_connection = nil
      connection:reject(err)
    end)
  return connection
end

local function publish_custom_server(server, server_pid)
  server:mark_ready()
  port_mapping.register(server.port, vim.fn.getcwd(), server_pid, server:can_release_process())
  state.jobs.set_server(server)
  return server
end

local function retry_connect(server, timeout, remaining)
  return try_custom_server(server, timeout):catch(function(err)
    if type(err) ~= 'table' or err.kind ~= 'transport' or remaining == 0 then
      return Promise.new():reject(err)
    end
    return Promise.delay(config.server.retry_delay or 2000):and_then(function()
      return retry_connect(server, timeout, remaining - 1)
    end)
  end)
end

function M.try_connect_to_custom_server(base_url, timeout, promise, custom_port, custom_url)
  local server = opencode_server.from_custom(base_url, custom_port)
  local credential_ok, credential = pcall(resolve_credential, false)
  if not credential_ok then
    promise:reject(credential)
    return
  end
  server.credential = credential
  local mapped_release = port_mapping.capture_process_release(custom_port)
  if mapped_release then
    server:set_process_release(mapped_release)
  end
  try_custom_server(server, timeout)
    :catch(function(err)
      -- Only a transport failure can mean that an explicitly configured launcher is needed.
      -- HTTP authentication and contract failures describe an existing server and must remain visible.
      if type(err) ~= 'table' or err.kind ~= 'transport' then
        return Promise.new():reject(err)
      end
      if not config.server.spawn_command then
        return retry_connect(server, timeout, 5)
      end
      server.credential = resolve_credential(true)
      local ok, result = pcall(config.server.spawn_command, custom_port, custom_url, auth.get_env(server.credential))
      if not ok then
        return Promise.new():reject(result)
      end
      server.custom_pid = type(result) == 'number' and result or nil
      if config.server.auto_kill then
        local kill_command = config.server.kill_command
        local pid = server.custom_pid
        if kill_command then
          server:set_process_release(function()
            kill_command(custom_port, custom_url)
          end)
        elseif pid then
          server:set_process_release(function()
            opencode_server.kill_pid(pid)
          end)
        end
      end
      return retry_connect(server, timeout, 3)
    end)
    :and_then(function(ready_server)
      publish_custom_server(ready_server, ready_server.custom_pid)
      promise:resolve(ready_server)
    end)
    :catch(function(err)
      promise:reject(err)
    end)
end

--- @param promise Promise<OpencodeServer>
--- @param port? number|string Optional custom port
--- @param hostname? string Optional custom hostname
function M.spawn_local_server(promise, port, hostname)
  local server = opencode_server.new()
  local credential_ok, credential = pcall(resolve_credential, true)
  if not credential_ok then
    promise:reject(credential)
    return
  end
  server.credential = credential
  local cwd = vim.fn.getcwd()
  local spawn_opts = {
    cwd = cwd,
    on_ready = function(job, base_url)
      local url_port = base_url:match(':(%d+)')
      log.notify(string.format('Started local server at %s', base_url), vim.log.levels.INFO)
      if url_port then
        local port_num = tonumber(url_port)
        if state.opencode_server == server then
          state.jobs.set_server_port(port_num)
        else
          server.port = port_num
        end
        local server_pid = job and job.pid
        log.debug(
          'spawn_local_server: registered port %d for reference counting (server_pid=%s)',
          port_num,
          tostring(server_pid)
        )
      end
      local probe = server:probe_connection()
      probe
        :and_then(function(probe_result)
          apply_probe(server, probe_result, server.job and server.job.pid)
          publish_custom_server(server, server.job and server.job.pid)
          promise:resolve(server)
        end)
        :catch(function(err)
          server:shutdown()
          promise:reject(err)
        end)
    end,
    on_error = function(err)
      log.notify(' Failed to start opencode server' .. vim.inspect(err), vim.log.levels.ERROR)
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
    hostname = hostname:gsub('^%a[%w+%.%-]*://', '')
    hostname = hostname:match('^[^/]+') or hostname
    spawn_opts.hostname = hostname
  end

  server:spawn(spawn_opts)
end

return M
