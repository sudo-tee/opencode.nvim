local util = require('opencode.util')
local safe_call = util.safe_call
local Promise = require('opencode.promise')

--- @class OpencodeServer
--- @field job any The vim.system job handle
--- @field url string|nil The server URL once ready
--- @field handle any Compatibility property for job.stop interface
--- @field spawn_promise Promise<OpencodeServer>
--- @field shutdown_promise Promise<boolean>
--- @field connected boolean True when attached to a remote server URL
local OpencodeServer = {}
OpencodeServer.__index = OpencodeServer

local function normalize_server_url(url)
  if type(url) ~= 'string' then
    return url
  end

  if url:match('^%d+%.%d+%.%d+%.%d+:%d+$') or url:match('^localhost:%d+$') then
    url = 'http://' .. url
  end

  url = url:gsub('/$', '')
  url = url:gsub('://0%.0%.0%.0', '://127.0.0.1')
  return url
end

local function extract_server_url(data)
  if type(data) ~= 'string' or data == '' then
    return nil
  end

  local url = data:match('opencode server listening on%s+([^%s]+)')
    or data:match('server listening at%s+([^%s]+)')
    or data:match('listening on%s+([^%s]+)')
    or data:match('listening at%s+([^%s]+)')

  if not url then
    url = data:match('(https?://127%.0%.0%.1:%d+)')
      or data:match('(https?://0%.0%.0%.0:%d+)')
      or data:match('(https?://localhost:%d+)')
      or data:match('(127%.0%.0%.1:%d+)')
      or data:match('(0%.0%.0%.0:%d+)')
      or data:match('(localhost:%d+)')
  end

  if not url then
    local lower = data:lower()
    if lower:find('listen', 1, true) then
      url = data:match('(https?://[^%s%]"\']+)')
    end
  end

  if url then
    url = url:gsub('[,;%.%)]$', '')
  end

  return url
end

local function append_chunk(buffer, chunk)
  if type(chunk) ~= 'string' or chunk == '' then
    return buffer
  end

  local next_buffer = buffer .. chunk
  if #next_buffer > 8192 then
    next_buffer = next_buffer:sub(-8192)
  end

  return next_buffer
end

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
      local log = require('opencode.log')
      if state.opencode_server then
        state.opencode_server:shutdown()
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
    handle = nil,
    spawn_promise = Promise.new(),
    shutdown_promise = Promise.new(),
    connected = false,
  }, OpencodeServer)
end

function OpencodeServer:is_running()
  if self.connected and self.url then
    return true
  end

  return self.job and self.job.pid ~= nil
end

---Attach to an already-running opencode server.
---@param url string
---@return Promise<OpencodeServer>
function OpencodeServer:connect(url)
  self.url = normalize_server_url(url)
  self.connected = self.url ~= nil and self.url ~= ''
  self.spawn_promise:resolve(self)
  return self.spawn_promise
end

local function kill_process(pid, signal, desc)
  local log = require('opencode.log')
  local ok, err = pcall(vim.uv.kill, pid, signal)
  log.debug('shutdown: %s pid=%d sig=%d ok=%s err=%s', desc, pid, signal, tostring(ok), tostring(err))
  return ok, err
end

function OpencodeServer:shutdown()
  local log = require('opencode.log')
  if self.shutdown_promise:is_resolved() then
    return self.shutdown_promise
  end

  if self.job and self.job.pid then
    ---@cast self.job vim.SystemObj
    local pid = self.job.pid
    local children = vim.api.nvim_get_proc_children(pid)

    if #children > 0 then
      log.debug('shutdown: process pid=%d has %d children (%s)', pid, #children, vim.inspect(children))

      for _, cid in ipairs(children) do
        kill_process(cid, 15, 'SIGTERM child')
      end
    end

    kill_process(pid, 15, 'SIGTERM')
    kill_process(pid, 9, 'SIGKILL')
  else
    log.debug('shutdown: no job running')
  end

  self.job = nil
  self.url = nil
  self.handle = nil
  self.connected = false
  self.shutdown_promise:resolve(true)
  return self.shutdown_promise
end

--- @class OpencodeServerSpawnOpts
--- @field cwd? string
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
  local stdout_buf = ''
  local stderr_buf = ''

  local function mark_ready(url, from_stderr)
    if ready then
      return
    end
    ready = true
    self.url = normalize_server_url(url)
    self.connected = true
    self.spawn_promise:resolve(self)
    safe_call(opts.on_ready, self.job, self.url)

    if from_stderr then
      log.debug('spawn: server ready at url=%s (detected from stderr)', self.url)
    else
      log.debug('spawn: server ready at url=%s', self.url)
    end
  end

  local cmd, cmd_err = util.get_runtime_serve_command()
  if not cmd then
    self.spawn_promise:reject(cmd_err)
    safe_call(opts.on_error, cmd_err)
    return self.spawn_promise
  end
  local system_opts = {
    cwd = opts.cwd,
  }

  self.job = vim.system(cmd, vim.tbl_extend('force', system_opts, {
    stdout = function(err, data)
      if err then
        if not ready then
          self.spawn_promise:reject(err)
        end
        safe_call(opts.on_error, err)
        return
      end

      if data then
        stdout_buf = append_chunk(stdout_buf, data)
        local url = extract_server_url(stdout_buf)
        if url then
          mark_ready(url, false)
        end
      end
    end,
    stderr = function(err, data)
      if err then
        if not ready then
          self.spawn_promise:reject(err)
        end
        safe_call(opts.on_error, err)
        return
      end

      if data then
        stderr_buf = append_chunk(stderr_buf, data)
        local url = extract_server_url(stderr_buf)
        if url then
          mark_ready(url, true)
          return
        end

        -- Filter out INFO/WARN/DEBUG log lines (not actual errors)
        local log_level = data:match('^%s*(%u+)%s')
        if log_level and (log_level == 'INFO' or log_level == 'WARN' or log_level == 'DEBUG') then
          -- Ignore log lines
          return
        end

        -- Some environments write non-fatal shell output to stderr during startup.
        -- Wait for either a ready URL from stdout or process exit before failing startup.
        if self.url then
          log.debug('spawn: stderr after ready: %s', vim.trim(data))
        else
          log.debug('spawn: stderr before ready: %s', vim.trim(data))
        end
      end
    end,
  }), function(exit_opts)
    if not ready then
      self.spawn_promise:reject(string.format('opencode server exited before ready (code=%s signal=%s)', tostring(exit_opts.code), tostring(exit_opts.signal)))
    end

    -- Clear fields if not already cleared by shutdown()
    self.job = nil
    self.url = nil
    self.handle = nil
    self.connected = false
    safe_call(opts.on_exit, exit_opts)
    self.shutdown_promise:resolve(true)
  end)

  self.handle = self.job and self.job.pid

  local startup_timeout_ms, timeout_err = util.get_runtime_startup_timeout_ms()
  if not startup_timeout_ms then
    self.spawn_promise:reject(timeout_err)
    safe_call(opts.on_error, timeout_err)
    return self.spawn_promise
  end

  vim.defer_fn(function()
    if ready then
      return
    end

    ready = true

    if self.job and self.job.kill then
      pcall(self.job.kill, self.job, 15)
      pcall(self.job.kill, self.job, 9)
    end

    local err = string.format(
      'Timed out waiting for opencode server startup after %dms. command=%s stdout=%s stderr=%s',
      startup_timeout_ms,
      vim.inspect(cmd),
      vim.inspect(vim.trim(stdout_buf)),
      vim.inspect(vim.trim(stderr_buf))
    )

    self.spawn_promise:reject(err)
    safe_call(opts.on_error, err)
  end, startup_timeout_ms)

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
