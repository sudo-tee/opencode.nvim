local util = require('opencode.util')
local safe_call = util.safe_call
local Promise = require('opencode.promise')
local auth = require('opencode.auth')
local protocol_connection = require('opencode.protocols.connection')

--- @class OpencodeServer
---@field job vim.SystemObj|nil The vim.system job handle
---@field url string|nil The server URL once ready
---@field port number|nil The port this server is using (for custom servers)
---@field handle integer|nil Compatibility property for job.stop interface
---@field protocol? 'v1'|'v2' Protocol selected by authenticated health probe
---@field version? string Server version returned by the selected health endpoint
---@field server_identity? {version: string, pid: integer|nil} Identity facts returned by the probe or acquisition
---@field credential? {username: string, password?: string} Credential owned by this connection
---@field operations? OpencodeV1Operations|OpencodeV2Operations Protocol operations selected when the connection becomes ready
---@field observations table<string, OpencodeObservation?> Observations owned by this connection
---@field shutdown_promise Promise<boolean>
---@field private _ready boolean
---@field private _shutdown_requested boolean
---@field private _release_process? fun()
---@field private _stream? {shutdown: fun(self: table)}
---@field private _requests table<table, true>
---@field private _observe? fun(connection: OpencodeServer, ref: {id: string, location?: OpencodeLocation}): OpencodeObservation
---@field private _close_observations? fun(connection: OpencodeServer)
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
      if state.opencode_server then
        state.opencode_server:close()
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
    protocol = nil,
    version = nil,
    server_identity = nil,
    credential = nil,
    operations = nil,
    observations = {},
    shutdown_promise = Promise.new(),
    _ready = false,
    _shutdown_requested = false,
    _release_process = nil,
    _stream = nil,
    _requests = {},
    _observe = nil,
    _close_observations = nil,
  }, OpencodeServer)
end

--- Create a server instance that connects to a custom server
--- @param url string The custom server URL
--- @param port number|nil The port number (for PID tracking)
--- @return OpencodeServer
function OpencodeServer.from_custom(url, port)
  local instance = OpencodeServer.new()
  instance.url = url
  instance.port = port

  return instance
end

---@return boolean
function OpencodeServer:is_ready()
  return self._ready
end

---@param release? fun()
function OpencodeServer:set_process_release(release)
  if self._ready or self.shutdown_promise:is_resolved() then
    error('cannot change release behavior of a ready connection')
  end
  self._release_process = release
end

---@return boolean
function OpencodeServer:can_release_process()
  return self._release_process ~= nil
end

---@return boolean
function OpencodeServer:release_process()
  local release = self._release_process
  self._release_process = nil
  if not release then
    return false
  end
  release()
  return true
end

---@param stream? {shutdown: fun(self: table)}
function OpencodeServer:set_stream(stream)
  if stream and self._stream then
    pcall(stream.shutdown, stream)
    error('Connection already owns an SSE stream')
  end
  if stream and not self:is_ready() then
    pcall(stream.shutdown, stream)
    error('cannot attach SSE to a closed Connection')
  end
  self._stream = stream
end

---@param request {shutdown: fun(self: table)}
function OpencodeServer:_track_request(request)
  if not self:is_ready() then
    pcall(request.shutdown, request)
    error('cannot attach HTTP request to a closed Connection')
  end
  self._requests[request] = true
end

---@param request table
function OpencodeServer:_untrack_request(request)
  self._requests[request] = nil
end

--- Publish the connection only after its authenticated protocol probe succeeds.
---@return OpencodeServer
function OpencodeServer:mark_ready()
  if self._ready then
    return self
  end
  if self.shutdown_promise:is_resolved() then
    error('cannot ready a closed Connection')
  end
  if type(self.url) ~= 'string' or self.url == '' then
    error('ready connection requires url')
  end
  local runtime = self.protocol and protocol_connection.runtime(self.protocol)
  if not runtime then
    error('ready connection requires protocol')
  end
  if
    type(self.server_identity) ~= 'table'
    or type(self.server_identity.version) ~= 'string'
    or self.server_identity.version == ''
  then
    error('ready connection requires server_identity')
  end
  if self.server_identity.pid ~= nil and type(self.server_identity.pid) ~= 'number' then
    error('ready connection server_identity pid must be a number')
  end
  self.version = self.server_identity.version
  if type(self.credential) ~= 'table' or type(self.credential.username) ~= 'string' then
    error('ready connection requires credential')
  end
  if self.credential.password ~= nil and type(self.credential.password) ~= 'string' then
    error('ready connection credential password must be a string')
  end
  self.operations = runtime.operations
  local observation_protocol = runtime.observation
  self._observe = observation_protocol.new
  self._close_observations = observation_protocol.close
  self._ready = true
  return self
end

---Return the unique Observation for a session on this Connection.
---@param ref {id: string, location?: OpencodeLocation}
---@return OpencodeObservation
function OpencodeServer:observe(ref)
  if not self:is_ready() or not self._observe then
    error('cannot observe a session on a closed Connection')
  end
  if type(ref) ~= 'table' or type(ref.id) ~= 'string' or ref.id == '' then
    error('observe requires a session id')
  end

  local existing = self.observations[ref.id]
  if existing then
    return existing
  end

  local observation = self._observe(self, ref)
  self.observations[ref.id] = observation
  return observation
end

--- Probe protocol using authenticated health endpoints.
---@param timeout_ms number|nil
---@return Promise<{protocol: 'v1'|'v2', response: table}>
function OpencodeServer:probe_connection(timeout_ms)
  return protocol_connection.probe(self, timeout_ms)
end

---Check if the server is reachable via its health endpoint.
---@return Promise<boolean>
function OpencodeServer:check_health()
  if not self._ready or not self.url then
    return Promise.new():resolve(false)
  end
  return protocol_connection.check_health(self)
end

---@return Promise<boolean>
function OpencodeServer:close()
  if self.shutdown_promise:is_resolved() then
    return self.shutdown_promise
  end

  self._shutdown_requested = true
  self._ready = false
  local close_observations = self._close_observations
  self._close_observations = nil
  if close_observations then
    close_observations(self)
  end
  local requests = self._requests
  self._requests = {}
  for request in pairs(requests) do
    pcall(request.shutdown, request)
  end

  local stream = self._stream
  self._stream = nil
  if stream then
    pcall(stream.shutdown, stream)
  end

  local released = false
  if self.port then
    released = require('opencode.port_mapping').unregister(self.port, self)
  end
  if not released then
    self:release_process()
  end

  self.job = nil
  self.handle = nil
  self.custom_pid = nil
  self.shutdown_promise:resolve(true)

  return self.shutdown_promise
end

---@return Promise<boolean>
function OpencodeServer:shutdown()
  return self:close()
end

--- @class OpencodeServerSpawnOpts
--- @field cwd? string
--- @field command string[]
--- @field auto_kill? boolean
--- @field listening_url fun(output: string): string|nil
--- @field on_ready fun(job: any, url: string)
--- @field on_error fun(err: any)
--- @field on_exit fun(exit_opts: vim.SystemCompleted )

--- Spawn the opencode server for this ServerJob instance.
--- @param opts OpencodeServerSpawnOpts
function OpencodeServer:spawn(opts)
  opts = opts or {}
  local log = require('opencode.log')
  self._shutdown_requested = false
  local listening = false
  local startup_failed = false
  local startup_stderr = {}

  if type(opts.command) ~= 'table' or #opts.command == 0 then
    error('spawn requires a command')
  end
  if type(opts.listening_url) ~= 'function' then
    error('spawn requires a listening URL parser')
  end
  local cmd = opts.command

  log.debug('spawn: starting opencode server with command: %s', vim.inspect(cmd))

  local function fail_startup(err)
    if self._ready or startup_failed or self._shutdown_requested then
      return
    end

    startup_failed = true
    safe_call(opts.on_error, err)
  end

  if opts.auto_kill ~= false then
    self:set_process_release(function()
      if self.job and self.job.pid then
        require('opencode.util').kill_pid(self.job.pid)
      end
    end)
  end
  self.job = vim.system(cmd, {
    cwd = opts.cwd,
    env = auth.get_env(self.credential),
    stdout = function(err, data)
      if err then
        fail_startup(err)
        return
      end
      if data then
        local url = opts.listening_url(data)
        if url and not listening then
          listening = true
          self.url = url
          safe_call(opts.on_ready, self.job, url)
          log.debug('spawn: server listening at url=%s', url)
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
    if not self._ready and not startup_failed and not self._shutdown_requested then
      local stderr_output = table.concat(startup_stderr)
      local startup_error = stderr_output ~= '' and stderr_output
        or string.format(
          'Opencode server exited before reporting ready state (code=%s, signal=%s)',
          tostring(exit_opts and exit_opts.code),
          tostring(exit_opts and exit_opts.signal)
        )
      fail_startup(startup_error)
    end

    self._release_process = nil
    self.job = nil
    self.handle = nil
    safe_call(opts.on_exit, exit_opts)
    self:close()
  end)

  self.handle = self.job and self.job.pid

  log.debug('spawn: started job with pid=%s', tostring(self.job and self.job.pid))
end

---@return Promise<boolean>
function OpencodeServer:get_shutdown_promise()
  return self.shutdown_promise
end

return OpencodeServer
