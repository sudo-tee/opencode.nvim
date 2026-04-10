local util = require('opencode.util')
local safe_call = util.safe_call
local Promise = require('opencode.promise')
local config = require('opencode.config')
local curl = require('opencode.curl')

--- @class OpencodeServer
--- @field job any The vim.system job handle
--- @field url string|nil The server URL once ready
--- @field port number|nil The port this server is using (for custom servers)
--- @field handle any Compatibility property for job.stop interface
--- @field mode? 'serve'|'custom'|'attach' The mode of this server instance
--- @field spawn_promise Promise<OpencodeServer>
--- @field shutdown_promise Promise<boolean>
local OpencodeServer = {}
OpencodeServer.__index = OpencodeServer

local vim_leave_setup = false
local function ensure_vim_leave_autocmd()
  if vim_leave_setup then
    return
  end
  vim_leave_setup = true

  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = vim.api.nvim_create_augroup('OpencodeVimLeavePre', { clear = true }),
    callback = function()
      local state = require('opencode.state')
      local server_job = require('opencode.server_job')
      if state.opencode_server then
        if state.opencode_server.port then
          server_job.unregister_port_usage(state.opencode_server.port)
        else
          state.opencode_server:shutdown()
        end
      end
    end,
  })
end

--- Create a new ServerJob instance
--- @return OpencodeServer
function OpencodeServer.new()
  ensure_vim_leave_autocmd()

  return setmetatable({
    job = nil,
    url = nil,
    port = nil,
    handle = nil,
    mode = nil,
    spawn_promise = Promise.new(),
    shutdown_promise = Promise.new(),
  }, OpencodeServer)
end

--- Create a server instance that connects to a custom server
--- @param url string The custom server URL
--- @param port number|nil The port number (for PID tracking)
--- @param mode? 'custom'|'attach' The mode of this server instance (default: 'custom')
--- @return OpencodeServer
function OpencodeServer.from_custom(url, port, mode)
  ensure_vim_leave_autocmd()

  local instance = setmetatable({
    job = nil,
    url = url,
    port = port,
    mode = mode or 'custom',
    handle = nil,
    spawn_promise = Promise.new(),
    shutdown_promise = Promise.new(),
  }, OpencodeServer)

  instance.spawn_promise:resolve(instance)

  return instance
end

function OpencodeServer:is_running()
  -- If this is a custom server (no job), check if URL is set
  if not self.job then
    return self.url ~= nil
  end
  -- Local server: check job pid
  return self.job.pid ~= nil
end

local function kill_process(pid, signal, desc)
  local log = require('opencode.log')
  local ok, err = pcall(vim.uv.kill, pid, signal)
  log.debug('shutdown: %s pid=%d sig=%d ok=%s err=%s', desc, pid, signal, tostring(ok), tostring(err))
  return ok, err
end

local function shutdown_custom_server(server)
  local log = require('opencode.log')
  if config.server.kill_command and config.server.auto_kill and server.port then
    log.debug('shutdown: custom server, executing kill_command for port %d (auto_kill=true)', server.port)
    local ok, result = pcall(config.server.kill_command, server.port, config.server.url or '127.0.0.1')
    if not ok then
      log.notify(string.format('Failed to execute kill_command: %s', tostring(result)), vim.log.levels.WARN)
    else
      log.debug('shutdown: kill_command executed successfully for port %d', server.port)
    end
  else
    if config.server.kill_command and not config.server.auto_kill then
      log.debug('shutdown: custom server, skipping kill_command (auto_kill=false)')
    else
      log.debug('shutdown: custom server, clearing URL only (no kill_command configured)')
    end
  end

  server.url = nil
  server.handle = nil
  server.shutdown_promise:resolve(true)
end

--- Kill a process tree by PID (children first, then parent).
--- SIGTERM is sent first, then SIGKILL immediately after as a backup.
--- @param pid number
function OpencodeServer.kill_pid(pid)
  local log = require('opencode.log')

  local ok, children = pcall(vim.api.nvim_get_proc_children, pid)
  if ok and children and #children > 0 then
    log.debug('kill_pid: pid=%d has %d children (%s)', pid, #children, vim.inspect(children))
    for _, cid in ipairs(children) do
      kill_process(cid, 15, 'SIGTERM child')
      kill_process(cid, 9, 'SIGKILL child')
    end
  end

  kill_process(pid, 15, 'SIGTERM')
  kill_process(pid, 9, 'SIGKILL')
end

--- Fire-and-forget POST to /global/shutdown on the given base URL.
--- @param base_url string e.g. "http://127.0.0.1:3000"
function OpencodeServer.request_graceful_shutdown(base_url)
  local log = require('opencode.log')
  local shutdown_url = base_url .. '/global/shutdown'
  log.info('request_graceful_shutdown: POST %s', shutdown_url)
  pcall(function()
    curl.request({
      url = shutdown_url,
      method = 'POST',
      timeout = 1000,
      proxy = '',
      callback = function(response)
        if response and response.status >= 200 and response.status < 300 then
          log.debug('request_graceful_shutdown: success for %s', base_url)
        end
      end,
      on_error = function(err)
        log.debug('request_graceful_shutdown: failed for %s: %s', base_url, vim.inspect(err))
      end,
    })
  end)
end

local function shutdown_local_server(server)
  local log = require('opencode.log')
  if not server.job.pid then
    log.debug('shutdown: no job running')
    server.job = nil
    server.url = nil
    server.handle = nil
    server.shutdown_promise:resolve(true)
    return
  end

  ---@cast server.job vim.SystemObj
  OpencodeServer.kill_pid(server.job.pid)

  server.job = nil
  server.url = nil
  server.handle = nil
  server.shutdown_promise:resolve(true)
end

function OpencodeServer:shutdown()
  if self.shutdown_promise:is_resolved() then
    return self.shutdown_promise
  end

  if not self.job then
    shutdown_custom_server(self, config)
  else
    shutdown_local_server(self)
  end

  return self.shutdown_promise
end

--- @class OpencodeServerSpawnOpts
--- @field cwd? string
--- @field port? number|string Custom port to use (will be converted to string for CLI)
--- @field hostname? string Custom hostname to bind to
--- @field on_ready fun(job: any, url: string)
--- @field on_error fun(err: any)
--- @field on_exit fun(exit_opts: vim.SystemCompleted )

--- Spawn the opencode server for this ServerJob instance.
--- @param opts? OpencodeServerSpawnOpts
--- @return Promise<OpencodeServer>
function OpencodeServer:spawn(opts)
  opts = opts or {}
  local log = require('opencode.log')
  local ready = false
  local startup_failed = false
  local startup_stderr = {}

  local cmd = {
    config.opencode_executable,
    'serve',
  }

  if opts.port then
    table.insert(cmd, '--port')
    table.insert(cmd, tostring(opts.port))
  end

  if opts.hostname then
    table.insert(cmd, '--hostname')
    table.insert(cmd, opts.hostname)
  end

  log.debug('spawn: starting opencode server with command: %s', vim.inspect(cmd))

  local function fail_startup(err)
    if ready or startup_failed then
      return
    end

    startup_failed = true
    self.spawn_promise:reject(err)
    safe_call(opts.on_error, err)
  end

  self.mode = 'serve'
  self.job = vim.system(cmd, {
    cwd = opts.cwd,
    stdout = function(err, data)
      if err then
        fail_startup(err)
        return
      end
      if data then
        local url = data:match('opencode server listening on ([^%s]+)')
        if url and not ready then
          ready = true
          self.url = url
          self.spawn_promise:resolve(self)
          safe_call(opts.on_ready, self.job, url)
          log.debug('spawn: server ready at url=%s', url)
        end
      end
    end,
    stderr = function(err, data)
      if err then
        fail_startup(err)
        return
      end
      if data and data ~= '' then
        table.insert(startup_stderr, data)
        log.debug('spawn: stderr output: %s', vim.inspect(data))
      end
    end,
  }, function(exit_opts)
    if not ready and not startup_failed then
      local stderr_output = table.concat(startup_stderr)
      local startup_error = stderr_output ~= '' and stderr_output
        or string.format(
          'Opencode server exited before reporting ready state (code=%s, signal=%s)',
          tostring(exit_opts and exit_opts.code),
          tostring(exit_opts and exit_opts.signal)
        )
      fail_startup(startup_error)
    end

    -- Clear fields if not already cleared by shutdown()
    self.job = nil
    self.url = nil
    self.handle = nil
    safe_call(opts.on_exit, exit_opts)
    self.shutdown_promise:resolve(true)
  end)

  self.handle = self.job and self.job.pid

  log.debug('spawn: started job with pid=%s', tostring(self.job and self.job.pid))
  return self.spawn_promise
end

function OpencodeServer:get_shutdown_promise()
  return self.shutdown_promise
end

function OpencodeServer:get_spawn_promise()
  return self.spawn_promise
end

return OpencodeServer
