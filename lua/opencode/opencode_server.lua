local util = require('opencode.util')
local safe_call = util.safe_call
local Promise = require('opencode.promise')

--- @class OpencodeServer
--- @field job any|nil The vim.system job handle (nil if using shared server)
--- @field url string|nil The server URL once ready
--- @field handle any Compatibility property for job.stop interface
--- @field spawn_promise Promise<OpencodeServer>
--- @field shutdown_promise Promise<boolean>
--- @field is_owner boolean Whether this instance owns the server process
--- @field pid number This instance's PID
local OpencodeServer = {}
OpencodeServer.__index = OpencodeServer

local current_pid = vim.fn.getpid()

local DEFAULT_PORT = 41096

--- @return string
local function get_lock_file_path()
  local tmpdir = vim.fn.stdpath('cache')
  return vim.fs.joinpath(tmpdir --[[@as string]], 'opencode-server.lock')
end

--- @param pid number
--- @return boolean
local function is_pid_alive(pid)
  if not pid or pid <= 0 then
    return false
  end
  local ok, result = pcall(vim.uv.kill, pid, 0)
  return ok and result == 0
end

--- @class LockFileData
--- @field url string
--- @field clients number[]
--- @field server_pid number|nil
--- @return LockFileData|nil
local function read_lock_file()
  local lock_path = get_lock_file_path()
  local f = io.open(lock_path, 'r')
  if not f then
    return nil
  end

  local content = f:read('*a')
  f:close()

  if not content or content == '' then
    return nil
  end

  local url = content:match('url=([^\n]+)')
  local clients_str = content:match('clients=([^\n]*)')
  local server_pid_str = content:match('server_pid=([^\n]+)')

  if not url then
    return nil
  end

  local server_pid = tonumber(server_pid_str)
  local clients = {}

  if clients_str and clients_str ~= '' then
    for pid_str in clients_str:gmatch('([^,]+)') do
      local pid = tonumber(pid_str)
      if pid then
        table.insert(clients, pid)
      end
    end
  end

  return { url = url, clients = clients, server_pid = server_pid }
end

--- @param data LockFileData
local function write_lock_file(data)
  local lock_path = get_lock_file_path()
  -- Ensure cache directory exists
  local cache_dir = vim.fn.stdpath('cache')
  if cache_dir and vim.fn.isdirectory(cache_dir) == 0 then
    vim.fn.mkdir(cache_dir, 'p')
  end
  local f = io.open(lock_path, 'w')
  if not f then
    return
  end

  local clients_str = table.concat(
    vim.tbl_map(function(pid)
      return tostring(pid)
    end, data.clients),
    ','
  )

  f:write(string.format('url=%s\nclients=%s\n', data.url, clients_str))
  if data.server_pid then
    f:write(string.format('server_pid=%d\n', data.server_pid))
  end
  f:close()
end

local function remove_lock_file()
  local lock_path = get_lock_file_path()
  os.remove(lock_path)
end

--- @param data LockFileData
--- @return LockFileData
local function cleanup_dead_pids(data)
  local alive_clients = vim.tbl_filter(function(pid)
    return is_pid_alive(pid)
  end, data.clients)

  data.clients = alive_clients

  return data
end

--- @param url string
--- @param server_pid number
local function create_lock_file(url, server_pid)
  write_lock_file({
    url = url,
    clients = { current_pid },
    server_pid = server_pid,
  })
end

--- @return boolean success
local function register_client()
  local data = read_lock_file()
  if not data then
    return false
  end

  data = cleanup_dead_pids(data)

  local already_registered = vim.tbl_contains(data.clients, current_pid)
  if not already_registered then
    table.insert(data.clients, current_pid)
  end

  write_lock_file(data)
  return true
end

--- @class UnregisterResult
--- @field server_pid number|nil
--- @field is_last_client boolean

--- @return UnregisterResult
local function unregister_client()
  local data = read_lock_file()
  if not data then
    return { server_pid = nil, is_last_client = false }
  end

  data = cleanup_dead_pids(data)

  data.clients = vim.tbl_filter(function(pid)
    return pid ~= current_pid
  end, data.clients)

  -- Always write updated lock file (even with empty clients)
  -- This allows new clients to register before we finish shutdown
  write_lock_file(data)

  if #data.clients == 0 then
    return { server_pid = data.server_pid, is_last_client = true }
  end

  return { server_pid = nil, is_last_client = false }
end

--- Check if we're still the last client (no new clients registered)
--- @return boolean
local function is_still_last_client()
  local data = read_lock_file()
  if not data then
    return true -- Lock file gone, we can proceed
  end
  data = cleanup_dead_pids(data)
  return #data.clients == 0
end

--- Find the PID of a process listening on the given port
--- @param port number|string
--- @return number|nil
local function find_pid_by_port(port)
  if vim.fn.has('win32') == 1 then
    -- Windows: use netstat
    local handle = io.popen('netstat -ano | findstr :' .. port .. ' | findstr LISTENING 2>nul')
    if handle then
      local output = handle:read('*a')
      handle:close()
      return tonumber(output:match('%s(%d+)%s*$'))
    end
  else
    -- Unix: use lsof
    local handle = io.popen('lsof -ti :' .. port .. ' 2>/dev/null')
    if handle then
      local output = handle:read('*a')
      handle:close()
      return tonumber(output:match('(%d+)'))
    end
  end
  return nil
end

--- Kill a process by PID with graceful shutdown
--- @param pid number
--- @param job any|nil Optional vim.system job handle
--- @return boolean success
local function kill_process(pid, job)
  if not pid or pid <= 0 then
    return false
  end

  if vim.fn.has('win32') == 1 then
    vim.fn.system({ 'taskkill', '/F', '/PID', tostring(pid) })
  else
    -- Unix: send SIGTERM first
    if job and job.pid then
      pcall(function()
        job:kill('sigterm')
      end)
    else
      pcall(vim.uv.kill, pid, 'sigterm')
    end

    -- Wait for process to exit (max 3 seconds)
    local start = os.time()
    while is_pid_alive(pid) and (os.time() - start) < 3 do
      vim.wait(100, function()
        return false
      end)
    end

    -- Force kill if still running
    if is_pid_alive(pid) then
      pcall(vim.uv.kill, pid, 'sigkill')
    end
  end

  return not is_pid_alive(pid)
end

--- @return OpencodeServer
function OpencodeServer.new()
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = vim.api.nvim_create_augroup('OpencodeVimLeavePre', { clear = true }),
    callback = function()
      local state = require('opencode.state')
      if state.opencode_server then
        -- Block and wait for shutdown to complete (max 5 seconds)
        state.opencode_server:shutdown():wait(5000)
      end
    end,
  })
  return setmetatable({
    job = nil,
    url = nil,
    handle = nil,
    is_owner = false,
    pid = current_pid,
    spawn_promise = Promise.new(),
    shutdown_promise = Promise.new(),
  }, OpencodeServer)
end

--- @return string|nil url Returns the server URL if an existing server is available
function OpencodeServer.try_existing_server()
  local data = read_lock_file()
  if not data then
    return nil
  end

  data = cleanup_dead_pids(data)

  if #data.clients == 0 then
    remove_lock_file()
    return nil
  end

  write_lock_file(data)
  local server_url = data.url

  local api_client = require('opencode.api_client')
  local is_healthy = api_client.check_health(server_url, 2000):wait(3000)

  if is_healthy then
    return server_url
  end

  remove_lock_file()
  return nil
end

--- @param url string
--- @return OpencodeServer
function OpencodeServer.from_existing(url)
  local server = OpencodeServer.new()
  server.url = url
  server.is_owner = false

  -- Try to register with existing lock file
  local registered = register_client()
  if not registered then
    -- No lock file exists - we need to find the server PID
    local port = url:match(':(%d+)/?$')
    local server_pid = port and find_pid_by_port(port) or nil

    write_lock_file({
      url = url,
      clients = { current_pid },
      server_pid = server_pid,
    })
  end

  server.spawn_promise:resolve(server --[[@as OpencodeServer]])
  return server
end

function OpencodeServer:is_running()
  if self.is_owner then
    return self.job and self.job.pid ~= nil
  end
  return self.url ~= nil
end

--- @return Promise<boolean>
function OpencodeServer:shutdown()
  local result = unregister_client()

  if result.is_last_client then
    -- Double-check: a new client may have registered while we were processing
    if not is_still_last_client() then
      -- New client registered, don't kill the server
      self.job = nil
      self.url = nil
      self.handle = nil
      self.shutdown_promise:resolve(true --[[@as boolean]])
      return self.shutdown_promise
    end

    -- Find the server PID to kill
    local server_pid_to_kill = result.server_pid
    if not server_pid_to_kill and self.url then
      -- Try to find by port if server_pid not recorded
      local port = self.url:match(':(%d+)/?$')
      if port then
        server_pid_to_kill = find_pid_by_port(port)
      end
    end

    if server_pid_to_kill then
      local killed = kill_process(server_pid_to_kill, self.job)
      if killed then
        remove_lock_file()
      end
      -- If kill failed, leave lock file so next client can try again
    else
      -- No PID found, just remove lock file
      remove_lock_file()
    end
  end

  self.job = nil
  self.url = nil
  self.handle = nil
  self.shutdown_promise:resolve(true --[[@as boolean]])
  return self.shutdown_promise
end

--- @class OpencodeServerSpawnOpts
--- @field cwd? string
--- @field port? number
--- @field on_ready fun(job: any, url: string)
--- @field on_error fun(err: any)
--- @field on_exit fun(exit_opts: vim.SystemCompleted )

--- @param opts? OpencodeServerSpawnOpts
--- @return Promise<OpencodeServer>
function OpencodeServer:spawn(opts)
  opts = opts or {}
  local port = opts.port or DEFAULT_PORT

  self.is_owner = true

  self.job = vim.system({
    'opencode',
    'serve',
    '--port',
    tostring(port),
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
          create_lock_file(url, self.job.pid)
          self.spawn_promise:resolve(self --[[@as OpencodeServer]])
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
    self.shutdown_promise:resolve(true --[[@as boolean]])
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
