local util = require('opencode.util')
local safe_call = util.safe_call
local Promise = require('opencode.promise')
local config = require('opencode.config')

--- @class OpencodeServer
--- @field job any The process handle and metadata
--- @field url string|nil The server URL once ready
--- @field handle any Compatibility property for job.stop interface
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

  vim.api.nvim_create_autocmd({ 'VimLeavePre', 'VimLeave' }, {
    group = vim.api.nvim_create_augroup('OpencodeVimLeavePre', { clear = true }),
    callback = function(event)
      local log = require('opencode.log')
      log.debug('VimLeave event triggered: %s', event.event)
      local state = require('opencode.state')
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
  }, OpencodeServer)
end

function OpencodeServer:is_running()
  return self.job and self.job.pid ~= nil
end

local function kill_process(pid, signal, desc, pgid)
  local log = require('opencode.log')
  local target = pgid and -pid or pid
  local ok, err = pcall(vim.uv.kill, assert(tonumber(target)), assert(tonumber(signal)))
  log.debug('shutdown: %s target=%d sig=%d ok=%s err=%s', desc, target, signal, tostring(ok), tostring(err))
  if ok then
    return true, nil
  else
    return false, tostring(err)
  end
end

--- Close a libuv pipe handle safely.
--- @param pipe userdata|nil
local function close_pipe(pipe)
  if pipe and not pipe:is_closing() then
    pipe:read_stop()
    pipe:close()
  end
end

function OpencodeServer:shutdown()
  local log = require('opencode.log')

  local pid = self.job and self.job.pid
  if self.shutdown_promise:is_resolved() and not pid then
    log.debug('shutdown: already resolved, returning existing promise %d', pid or -1)
    return self.shutdown_promise
  end

  if self.job and self.job.pid then
    local process_handle = self.job.process_handle

    kill_process(pid, 15, 'SIGTERM process group', true)
    kill_process(pid, 15, 'SIGTERM direct', false)

    kill_process(pid, 9, 'SIGKILL process group (escalation)', true)
    kill_process(pid, 9, 'SIGKILL direct (escalation)', false)

    -- Close the process handle if still alive
    if process_handle and not process_handle:is_closing() then
      process_handle:close()
    end

    close_pipe(self.job.stdout_pipe)
    close_pipe(self.job.stderr_pipe)
  else
    log.debug('shutdown: no job running')
  end

  self.job = nil
  self.url = nil
  self.handle = nil
  self.shutdown_promise:resolve(true)
  return self.shutdown_promise
end

--- @class OpencodeServerSpawnOpts
--- @field cwd? string
--- @field on_ready fun(job: any, url: string)
--- @field on_error fun(err: any)
--- @field on_exit fun(exit_opts: vim.SystemCompleted)

--- Spawn the opencode server for this ServerJob instance.
--- Uses vim.uv.spawn with detached=true so the server and all its children
--- belong to their own process group, allowing reliable cleanup on shutdown.
--- @param opts? OpencodeServerSpawnOpts
--- @return Promise<OpencodeServer>
function OpencodeServer:spawn(opts)
  opts = opts or {}
  local log = require('opencode.log')

  local stdout_pipe = vim.uv.new_pipe(false)
  local stderr_pipe = vim.uv.new_pipe(false)

  if not stdout_pipe or not stderr_pipe then
    local err = 'Failed to create libuv pipes'
    self.spawn_promise:reject(err)
    safe_call(opts.on_error, err)
    return self.spawn_promise
  end

  local process_handle, pid
  process_handle, pid = vim.uv.spawn(config.opencode_executable, {
    args = { 'serve' },
    cwd = opts.cwd,
    stdio = { nil, stdout_pipe, stderr_pipe },
    detached = true, -- new process group
  }, function(code, signal)
    -- on_exit callback from libuv — runs on the libuv thread so schedule
    -- back into the main loop for safe nvim API access.
    vim.schedule(function()
      close_pipe(stdout_pipe)
      close_pipe(stderr_pipe)

      if process_handle and not process_handle:is_closing() then
        process_handle:close()
      end

      -- Clear fields if not already cleared by shutdown()
      self.job = nil
      self.url = nil
      self.handle = nil

      safe_call(opts.on_exit, { code = code, signal = signal })
      if not self.shutdown_promise:is_resolved() then
        self.shutdown_promise:resolve(true)
      end
    end)
  end)

  if not process_handle then
    close_pipe(stdout_pipe)
    close_pipe(stderr_pipe)
    local err = 'Failed to spawn opencode: ' .. tostring(pid)
    self.spawn_promise:reject(err)
    safe_call(opts.on_error, err)
    return self.spawn_promise
  end

  -- Store everything callers and shutdown() need
  self.job = {
    pid = pid,
    process_handle = process_handle,
    stdout_pipe = stdout_pipe,
    stderr_pipe = stderr_pipe,
  }
  self.handle = pid

  -- Read stdout for the "listening on …" line
  stdout_pipe:read_start(function(err, data)
    if err then
      safe_call(opts.on_error, err)
      return
    end
    if data then
      local url = data:match('opencode server listening on ([^%s]+)')
      if url then
        self.url = url
        self.spawn_promise:resolve(self)
        safe_call(opts.on_ready, self.job, url)
        log.debug('spawn: server ready at url=%s', url)
      end
    end
  end)

  -- Read stderr — only treat real errors as rejections
  stderr_pipe:read_start(function(err, data)
    if err then
      self.spawn_promise:reject(err)
      safe_call(opts.on_error, err)
      return
    end
    if data then
      -- Filter out INFO/WARN/DEBUG log lines (not actual errors)
      local log_level = data:match('^%s*(%u+)%s')
      if log_level and (log_level == 'INFO' or log_level == 'WARN' or log_level == 'DEBUG') then
        return
      end
      -- Only reject on actual errors
      self.spawn_promise:reject(data)
      safe_call(opts.on_error, data)
    end
  end)

  log.debug('spawn: started job with pid=%s (detached process group)', tostring(pid))
  return self.spawn_promise
end

function OpencodeServer:get_shutdown_promise()
  return self.shutdown_promise
end

function OpencodeServer:get_spawn_promise()
  return self.spawn_promise
end

return OpencodeServer
