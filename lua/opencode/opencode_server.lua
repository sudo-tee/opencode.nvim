local util = require('opencode.util')
local safe_call = util.safe_call
local Promise = require('opencode.promise')

--- @class OpencodeServer
--- @field job any The vim.system job handle
--- @field url string|nil The server URL once ready
--- @field handle any Compatibility property for job.stop interface
--- @field spawn_promise Promise|nil
--- @field shutdown_promise Promise|nil
local OpencodeServer = {}
OpencodeServer.__index = OpencodeServer

--- Create a new ServerJob instance
--- @return OpencodeServer
function OpencodeServer.new()
  --- before quitting vim ensure we close opencode server
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = vim.api.nvim_create_augroup('OpencodeVimLeavePre', { clear = true }),
    callback = function()
      local state = require('opencode.state')
      if state.opencode_server_job then
        state.opencode_server_job:shutdown()
      end
    end,
  })
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

--- Clean up this server job
--- @return Promise<boolean>
function OpencodeServer:shutdown()
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
    self.job = nil
    self.url = nil
    self.handle = nil
    safe_call(opts.on_exit, exit_opts)
    self.shutdown_promise:resolve(true)
  end)

  self.handle = self.job and self.job.pid

  return self.spawn_promise
end

function OpencodeServer:get_shutdown_promise()
  return self.shutdown_promise
end

function OpencodeServer:get_spawn_promise()
  return self.spawn_promise
end

return OpencodeServer
