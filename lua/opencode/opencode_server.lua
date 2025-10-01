local util = require('opencode.util')
local safe_call = util.safe_call
local Promise = require('opencode.promise')
local EventListener = require('opencode.event_listener')
local PermissionManager = require('opencode.permission_manager')

--- @class OpencodeServer
--- @field job any The vim.system job handle
--- @field url string|nil The server URL once ready
--- @field handle any Compatibility property for job.stop interface
--- @field spawn_promise Promise|nil
--- @field interrupt_promise Promise|nil
--- @field shutdown_promise Promise|nil
--- @field event_listener EventListener|nil
--- @field permission_manager PermissionManager|nil
local OpencodeServer = {}
OpencodeServer.__index = OpencodeServer

--- Create a new ServerJob instance
--- @return OpencodeServer
function OpencodeServer.new()
  return setmetatable({
    job = nil,
    url = nil,
    handle = nil,
    spawn_promise = Promise.new(),
    interrupt_promise = Promise.new(),
    shutdown_promise = Promise.new(),
    event_listener = nil,
    permission_manager = nil,
  }, OpencodeServer)
end

--- Clean up this server job
--- @return Promise<boolean>
function OpencodeServer:shutdown()
  if self.event_listener then
    self.event_listener:stop()
    self.event_listener = nil
  end
  if self.permission_manager then
    self.permission_manager:clear()
    self.permission_manager = nil
  end
  if self.job and self.job.pid then
    pcall(function()
      self.job:kill('sigterm')
    end)
  end
  self.job = nil
  self.url = nil
  self.handle = nil
  self.shutdown_promise:resolve(true)
  return self.shutdown_promise
end

function OpencodeServer:on_interrupt()
  self.interrupt_promise:resolve(true)
end

--- @class OpencodeServerSpawnOpts
--- @field cwd string
--- @field on_ready fun(job: any, url: string)
--- @field on_error fun(err: any)
--- @field on_exit fun(exit_opts: vim.SystemCompleted )

--- Spawn the opencode server for this ServerJob instance.
--- @param opts? OpencodeServerSpawnOpts
--- @return Promise<OpencodeServer>
function OpencodeServer:spawn(opts)
  self.spawn_promise = Promise.new()
  self.interrupt_promise = Promise.new()
  self.shutdown_promise = Promise.new()
  opts = opts or {}

  self.job = vim.system({
    'opencode',
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

          self:_start_event_listener(url)

          safe_call(opts.on_ready, self.job, url)
        end
      end
    end,
    stderr = function(err, data)
      if err or data then
        self.spawn_promise:reject(err or data)
        safe_call(opts.on_error, err or data)
      end
    end,
  }, function(exit_opts)
    if self.event_listener then
      self.event_listener:stop()
      self.event_listener = nil
    end
    if self.permission_manager then
      self.permission_manager:clear()
      self.permission_manager = nil
    end
    self.job = nil
    self.url = nil
    self.handle = nil
    safe_call(opts.on_exit, exit_opts)
    self.shutdown_promise:resolve(true)
  end)

  self.handle = self.job and self.job.pid

  return self.spawn_promise
end

function OpencodeServer:_start_event_listener(base_url)
  if not base_url or base_url == '' then
    return
  end

  self.permission_manager = PermissionManager.new(base_url)
  self.event_listener = EventListener.new()

  self.event_listener:on('permission.updated', function(data)
    vim.notify('🔔 Permission event received!', vim.log.levels.INFO)
    vim.notify('Event data: ' .. vim.inspect(data), vim.log.levels.INFO)
    if self.permission_manager then
      self.permission_manager:handle_request(data)
    else
      vim.notify('❌ No permission_manager!', vim.log.levels.ERROR)
    end
  end)

  self.event_listener:on('error', function(err)
    vim.notify(
      string.format('Event listener error: %s', err.message or vim.inspect(err)),
      vim.log.levels.WARN
    )
  end)

  self.event_listener:start(base_url)
end

function OpencodeServer:get_interrupt_promise()
  return self.interrupt_promise
end

function OpencodeServer:get_shutdown_promise()
  return self.shutdown_promise
end

function OpencodeServer:get_spawn_promise()
  return self.spawn_promise
end

return OpencodeServer
