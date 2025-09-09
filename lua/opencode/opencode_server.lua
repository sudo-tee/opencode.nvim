local util = require('opencode.util')
local safe_call = util.safe_call
local Promise = require('opencode.promise')

--- @class OpencodeServer
--- @field job any The vim.system job handle
--- @field url string|nil The server URL once ready
--- @field handle any Compatibility property for job.stop interface
--- @field shutdown_promise Promise|nil
local OpencodeServer = {}
OpencodeServer.__index = OpencodeServer

--- Create a new ServerJob instance
--- @return OpencodeServer
function OpencodeServer.new()
  return setmetatable({
    job = nil,
    url = nil,
    handle = nil,
    shutdown_promise = Promise.new(),
  }, OpencodeServer)
end

--- Clean up this server job
function OpencodeServer:shutdown()
  if self.job and self.job.pid then
    pcall(function()
      self.job:kill('sigterm')
    end)
  end
  self.job = nil
  self.url = nil
  self.handle = nil
  return self.shutdown_promise
end

function OpencodeServer:on_interrupt()
  self.shutdown_promise:resolve(true)
end

--- @class OpencodeServerSpawnOpts
--- @field cwd string
--- @field on_ready fun(job: any, url: string)
--- @field on_error fun(err: any)
--- @field on_exit fun(code: integer)

--- Spawn the opencode server for this ServerJob instance.
--- @param opts OpencodeServerSpawnOpts
--- @return OpencodeServer self
function OpencodeServer:spawn(opts)
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
          safe_call(opts.on_ready, self.job, url)
        end
      end
    end,
    stderr = function(err, data)
      if err or data then
        safe_call(opts.on_error, err or data)
      end
    end,
    exit = function(code, signal)
      self.job = nil
      self.url = nil
      self.handle = nil
      self.shutdown_promise:resolve(true)
      safe_call(opts.on_exit, code)
    end,
  })

  self.handle = self.job and self.job.pid

  return self
end

function OpencodeServer:get_shutdown_promise()
  return self.shutdown_promise
end

return OpencodeServer
