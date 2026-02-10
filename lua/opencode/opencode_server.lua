local util = require('opencode.util')
local safe_call = util.safe_call
local Promise = require('opencode.promise')
local config = require('opencode.config')

--- @class OpencodeServer
--- @field job any The vim.system job handle
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
  local log = require('opencode.log')
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

  self.job = vim.system({
    config.opencode_executable,
    'serve',
  }, {
    cwd = opts.cwd,
    stdout = function(err, data)
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
    end,
    stderr = function(err, data)
      if err then
        self.spawn_promise:reject(err)
        safe_call(opts.on_error, err)
        return
      end
      if data then
        -- Filter out INFO/WARN/DEBUG log lines (not actual errors)
        local log_level = data:match('^%s*(%u+)%s')
        if log_level and (log_level == 'INFO' or log_level == 'WARN' or log_level == 'DEBUG') then
          -- Ignore log lines, don't reject
          return
        end
        -- Only reject on actual errors
        self.spawn_promise:reject(data)
        safe_call(opts.on_error, data)
      end
    end,
  }, function(exit_opts)
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
