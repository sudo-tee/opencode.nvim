local log = require('opencode.log')
local OpencodeServer = require('opencode.opencode_server')

local M = {}

-- Signal 0 only checks if a process exists, doesn't actually signal it
local SIG_PID_EXISTS = 0

--- @class PortMappingEntry
--- @field pid number
--- @field directory string

--- @class PortMapping
--- @field directory string
--- @field nvim_pids PortMappingEntry[]
--- @field auto_kill boolean
--- @field started_by_nvim boolean
--- @field server_pid number|nil The PID of the opencode server process (local servers only)
--- @field release_process boolean|nil Whether the last registered client may release server_pid

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

--- @param entry PortMappingEntry
--- @return boolean
local function pid_alive(entry)
  return vim.fn.getpid() == entry.pid or vim.uv.kill(entry.pid, SIG_PID_EXISTS) == 0
end

local function can_release(mapping)
  if mapping.release_process ~= nil then
    return mapping.release_process
  end
  if mapping.ownership ~= nil then
    return mapping.ownership == 'plugin_spawned' and mapping.auto_kill ~= false
  end
  return mapping.started_by_nvim == true and mapping.auto_kill ~= false
end

---@param server_pid number|nil
local function kill_orphaned_server(server_pid)
  if server_pid then
    OpencodeServer.kill_pid(server_pid)
  else
    log.debug('port_mapping: no server PID available for orphaned private server')
  end
end

--- Purge dead nvim PIDs from every mapping and kill any newly-orphaned servers.
local function clean_stale()
  local mappings = load()
  local changed = false

  for port_key, mapping in pairs(mappings) do
    mapping.nvim_pids = mapping.nvim_pids or {}
    local before = #mapping.nvim_pids

    mapping.nvim_pids = vim.tbl_filter(pid_alive, mapping.nvim_pids)

    if #mapping.nvim_pids < before then
      changed = true
    end

    if #mapping.nvim_pids == 0 then
      local port = tonumber(port_key)
      if port and can_release(mapping) then
        kill_orphaned_server(mapping.server_pid)
      end
      log.debug('port_mapping: removing port %s (no connected clients)', port_key)
      mappings[port_key] = nil
      changed = true
    end
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
--- @param server_pid? number The PID of the server process (local servers only)
--- @param release_process boolean Whether the last client may release the process
function M.register(port, directory, server_pid, release_process)
  clean_stale()

  local mappings = load()
  local port_key = tostring(port)
  local current_pid = vim.fn.getpid()
  if not mappings[port_key] then
    mappings[port_key] = {
      directory = directory,
      nvim_pids = {},
      release_process = release_process == true,
    }
  end

  local mapping = mappings[port_key]
  mapping.nvim_pids = mapping.nvim_pids or {}
  if release_process then
    mapping.release_process = true
  end
  -- Only update server_pid if provided (don't overwrite existing PID with nil)
  if server_pid then
    mapping.server_pid = server_pid
  end

  local pid_exists = false
  local updated = {}
  for _, entry in ipairs(mapping.nvim_pids) do
    table.insert(updated, entry)
    if entry.pid == current_pid then
      pid_exists = true
    end
  end
  mapping.nvim_pids = updated

  if not pid_exists then
    table.insert(mapping.nvim_pids, { pid = current_pid, directory = directory })
  end

  save(mappings)
  log.debug(
    'port_mapping.register: port=%d dir=%s pid=%d release_process=%s server_pid=%s',
    port,
    directory,
    current_pid,
    tostring(can_release(mapping)),
    tostring(server_pid)
  )
end

--- Remove this nvim instance from a port's client list.
--- Shuts the server down when it was the last client and auto_kill is set.
--- @param port number|nil
--- @param server OpencodeServer instance (state.opencode_server)
--- @return boolean handled Whether a mapping governed the release decision
function M.unregister(port, server)
  if not port then
    return false
  end

  clean_stale()
  local mappings = load()
  local port_key = tostring(port)
  local mapping = mappings[port_key]
  if not mapping then
    return false
  end

  local current_pid = vim.fn.getpid()
  local remaining = {}
  for _, entry in ipairs(mapping.nvim_pids or {}) do
    if entry.pid ~= current_pid then
      table.insert(remaining, entry)
    end
  end
  mapping.nvim_pids = remaining

  if #remaining == 0 and can_release(mapping) then
    if server then
      server:release_process()
    else
      kill_orphaned_server(mapping.server_pid)
    end
  end

  if #remaining == 0 then
    mappings[port_key] = nil
  else
    log.debug('port_mapping.unregister: port=%d still has %d client(s)', port, #remaining)
  end

  save(mappings)
  return true
end

---@param port number
---@return (fun())|nil
function M.capture_process_release(port)
  local mapping = load()[tostring(port)]
  if not mapping or not can_release(mapping) or not mapping.server_pid then
    return nil
  end
  local server_pid = mapping.server_pid
  return function()
    OpencodeServer.kill_pid(server_pid)
  end
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
