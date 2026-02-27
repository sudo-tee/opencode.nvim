local curl = require('opencode.curl')
local log = require('opencode.log')
local config = require('opencode.config')
local util = require('opencode.util')

local M = {}

--- @class PortMappingEntry
--- @field pid number
--- @field directory string
--- @field mode string

--- @class PortMapping
--- @field directory string
--- @field nvim_pids PortMappingEntry[]
--- @field auto_kill boolean
--- @field started_by_nvim boolean
--- @field url string|nil The URL the opencode server is listening on
--- @field server_pid number|nil The PID of the opencode server process (local servers only)

--- @return string
local function file_path()
  return vim.fn.stdpath('data') .. '/opencode_port_mappings.json'
end

--- @return table<string, PortMapping>
local function load()
  local file = io.open(file_path(), 'r')
  if not file then
    return {}
  end
  local content = file:read('*all')
  file:close()
  local ok, data = pcall(vim.json.decode, content or '')
  return ok and data or {}
end

--- @param mappings table<string, PortMapping>
local function save(mappings)
  local path = file_path()
  local file = io.open(path, 'w')
  if not file then
    log.warn('port_mapping: could not open %s for writing', path)
    return
  end
  file:write(vim.json.encode(mappings))
  file:close()
end

--- @param raw number|PortMappingEntry
--- @param fallback_dir string
--- @return PortMappingEntry
local function normalize(raw, fallback_dir)
  if type(raw) == 'number' then
    return { pid = raw, directory = fallback_dir, mode = 'serve' }
  end
  return raw
end

--- Fire-and-forget graceful shutdown request to a server with no clients.
--- Also force-kills the process if server_pid is available.
--- Uses async operations to avoid blocking Neovim shutdown.
--- @param port number
--- @param server_pid number|nil
local function kill_orphaned_server(port, server_pid)
  local server_url = config.server.url or '127.0.0.1'
  local normalized_url = util.normalize_url_protocol(server_url)
  local base_url = string.format('%s:%d', normalized_url, port)
  local shutdown_url = base_url .. '/global/shutdown'
  
  log.info('port_mapping: sending shutdown to orphaned server at %s (server_pid=%s)', base_url, tostring(server_pid))
  
  -- First attempt graceful shutdown via API (already async via curl.request)
  pcall(function()
    curl.request({
      url = shutdown_url,
      method = 'POST',
      timeout = 1000,
      proxy = '',
      callback = function(response)
        if response and response.status >= 200 and response.status < 300 then
          log.debug('port_mapping: graceful shutdown successful for %s', base_url)
        end
      end,
      on_error = function(err)
        log.debug('port_mapping: shutdown request failed for %s: %s', base_url, vim.inspect(err))
      end,
    })
  end)
  
  -- If we have a server PID, force kill it using async timers to avoid blocking
  if server_pid then
    -- Schedule async kill sequence without blocking
    vim.defer_fn(function()
      -- Check for and kill child processes first
      local ok, children = pcall(vim.api.nvim_get_proc_children, server_pid)
      if ok and children and #children > 0 then
        log.debug('port_mapping: server pid=%d has %d children, killing them', server_pid, #children)
        for _, child_pid in ipairs(children) do
          pcall(vim.uv.kill, child_pid, 15) -- SIGTERM
          -- Schedule SIGKILL for stubborn children
          vim.defer_fn(function()
            pcall(vim.uv.kill, child_pid, 9)
          end, 100)
        end
      end
      
      -- Kill the main server process
      local ok, err = pcall(vim.uv.kill, server_pid, 15) -- SIGTERM
      log.debug('port_mapping: SIGTERM server pid=%d ok=%s err=%s', server_pid, tostring(ok), tostring(err))
      
      -- Schedule SIGKILL for stubborn processes
      vim.defer_fn(function()
        local ok, err = pcall(vim.uv.kill, server_pid, 9) -- SIGKILL
        log.debug('port_mapping: SIGKILL server pid=%d ok=%s err=%s', server_pid, tostring(ok), tostring(err))
      end, 100)
    end, 500)
  else
    log.debug('port_mapping: no server PID available, relying on graceful shutdown only')
  end
end

--- Purge dead nvim PIDs from every mapping and kill any newly-orphaned servers.
local function clean_stale()
  local mappings = load()
  local changed = false

  for port_key, mapping in pairs(mappings) do
    if not mapping.nvim_pids then
      goto continue
    end

    local alive = {}
    for _, raw in ipairs(mapping.nvim_pids) do
      local entry = normalize(raw, mapping.directory)
      local is_alive = vim.fn.getpid() == entry.pid or vim.uv.kill(entry.pid, 0)
      if is_alive then
        table.insert(alive, entry)
      end
      if type(raw) == 'number' or not is_alive then
        changed = true
      end
    end
    mapping.nvim_pids = alive

    if #alive == 0 then
      local port = tonumber(port_key)
      if port and mapping.started_by_nvim then
        kill_orphaned_server(port, mapping.server_pid)
      end
      log.debug('port_mapping: removing port %s (no connected clients)', port_key)
      mappings[port_key] = nil
      changed = true
    end

    ::continue::
  end

  if changed then
    save(mappings)
  end
end

--- Return the directory a port is already mapped to, or nil when the port is
--- either free or already mapped to current_dir.
--- @param port number
--- @param current_dir string
--- @return string|nil
function M.mapped_directory(port, current_dir)
  clean_stale()
  local mapping = load()[tostring(port)]
  if mapping and mapping.directory and mapping.directory ~= current_dir then
    return mapping.directory
  end
end

--- Return an existing port serving current_dir, or nil.
--- @param current_dir string
--- @return number|nil
function M.find_port_for_directory(current_dir)
  clean_stale()
  for port_key, mapping in pairs(load()) do
    if mapping.directory == current_dir and mapping.nvim_pids and #mapping.nvim_pids > 0 then
      local port = tonumber(port_key)
      if port then
        return port
      end
    end
  end
end

--- Record that this nvim instance is using the given port.
--- @param port number
--- @param directory string
--- @param started_by_nvim boolean
--- @param mode? string 'serve'|'attach'|'custom'
--- @param url? string The URL the server is listening on
--- @param server_pid? number The PID of the server process (local servers only)
function M.register(port, directory, started_by_nvim, mode, url, server_pid)
  mode = mode or 'serve'
  clean_stale()

  local mappings = load()
  local port_key = tostring(port)
  local current_pid = vim.fn.getpid()
  local auto_kill = config.server.auto_kill

  if not mappings[port_key] then
    mappings[port_key] = {
      directory = directory,
      nvim_pids = {},
      auto_kill = auto_kill,
      started_by_nvim = started_by_nvim,
    }
  end

  local mapping = mappings[port_key]
  mapping.nvim_pids = mapping.nvim_pids or {}
  if mapping.auto_kill == nil then
    mapping.auto_kill = auto_kill
  end
  if mapping.started_by_nvim == nil then
    mapping.started_by_nvim = started_by_nvim
  end
  if url then
    mapping.url = url
  end
  -- Only update server_pid if provided (don't overwrite existing PID with nil)
  if server_pid then
    mapping.server_pid = server_pid
  end

  local pid_exists = false
  local updated = {}
  for _, raw in ipairs(mapping.nvim_pids) do
    local entry = normalize(raw, mapping.directory)
    table.insert(updated, entry)
    if entry.pid == current_pid then
      pid_exists = true
    end
  end
  mapping.nvim_pids = updated

  if not pid_exists then
    table.insert(mapping.nvim_pids, { pid = current_pid, directory = directory, mode = mode })
  end

  save(mappings)
  log.debug(
    'port_mapping.register: port=%d dir=%s pid=%d mode=%s started_by_nvim=%s auto_kill=%s url=%s server_pid=%s',
    port,
    directory,
    current_pid,
    mode,
    tostring(started_by_nvim),
    tostring(auto_kill),
    tostring(url),
    tostring(server_pid)
  )
end

--- Remove this nvim instance from a port's client list.
--- Shuts the server down when it was the last client and auto_kill is set.
--- Also shuts down attach-mode processes unconditionally.
--- @param port number|nil
--- @param server any OpencodeServer instance (state.opencode_server)
function M.unregister(port, server)
  if not port then
    return
  end

  clean_stale()
  local mappings = load()
  local port_key = tostring(port)
  local mapping = mappings[port_key]
  if not mapping then
    return
  end

  local current_pid = vim.fn.getpid()
  local remaining = {}
  for _, raw in ipairs(mapping.nvim_pids or {}) do
    local entry = normalize(raw, mapping.directory)
    if entry.pid ~= current_pid then
      table.insert(remaining, entry)
    end
  end
  mapping.nvim_pids = remaining

  local should_shutdown = #remaining == 0 and mapping.started_by_nvim and mapping.auto_kill

  if server then
    if server.mode == 'attach' or should_shutdown then
      log.debug('port_mapping.unregister: shutting down server for port %d', port)
      server:shutdown()
    end
  elseif should_shutdown then
    -- No server object available, kill directly using tracked PID
    log.debug('port_mapping.unregister: last nvim instance for port %d, killing orphaned server', port)
    kill_orphaned_server(port, mapping.server_pid)
  end

  if should_shutdown then
    mappings[port_key] = nil
  else
    log.debug('port_mapping.unregister: port=%d still has %d client(s)', port, #remaining)
  end

  save(mappings)
end

--- Return the started_by_nvim flag for a port, or false if unknown.
--- @param port number
--- @return boolean
function M.started_by_nvim(port)
  local mapping = load()[tostring(port)]
  return mapping and mapping.started_by_nvim or false
end

--- Find any existing server port (regardless of directory)
--- @return number|nil port number if found, nil otherwise
function M.find_any_existing_port()
  clean_stale()
  local mappings = load()
  
  for port_key, mapping in pairs(mappings) do
    if mapping.nvim_pids and #mapping.nvim_pids > 0 then
      local port = tonumber(port_key)
      if port then
        return port
      end
    end
  end
  
  return nil
end

return M
