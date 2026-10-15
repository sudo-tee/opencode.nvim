local config = require('opencode.config')
local tabs = require('opencode.state.session_tabs')
local server_job = require('opencode.server_job')
local Promise = require('opencode.promise')
local util = require('opencode.util')
local log = require('opencode.log')
local v = require('opencode.shape')

local M = {}
---@class OpencodeTabGroup
---@field project string
---@field server string
---@field cwd string
---@field attempted boolean
---@field failed boolean
---@field restoring boolean
---@field restore_generation? integer

---@type table<string, OpencodeTabGroup>
local groups = {}
---@type OpencodeTabGroup|nil
local owner
local generation = 0
---@type string|nil
local requested_cwd
---@type string|nil
local requested_server
---@type Promise<nil>|nil
local pending_restore

---@class OpencodeSavedSessionTab
---@field session_id string
---@field directory string
---@field bound_directory? string
---@field session_locked? boolean

---@class OpencodeSessionTabSnapshot
---@field version integer
---@field cwd string
---@field project string
---@field server string
---@field tabs OpencodeSavedSessionTab[]
---@field active_index integer

-- The snapshot file is external input: it may be corrupt or hand-edited.
local saved_tabs_shape = v.array(v.object({
  session_id = 'string',
  directory = 'string',
  bound_directory = v.optional('string'),
  session_locked = v.optional('boolean'),
}))
local snapshot_shape = v.object({
  version = v.literal(2),
  cwd = 'string',
  project = 'string',
  server = 'string',
  active_index = v.integer(),
  tabs = saved_tabs_shape,
})
local project_shape = v.object({ id = 'string' })

---@alias OpencodePersistedSessionLookup fun(connection: OpencodeV1Connection|OpencodeV2Connection, session_id: string, location: OpencodeLocation, path_map: OpencodePathMap, reverse_path_map: OpencodePathMap): Promise<OpencodeSession>

---@return string
local function server_identity()
  -- Use configured identity, not a discovered/random port that changes on restart.
  local server = vim.json.encode({
    config.opencode_executable,
    config.server.url or '',
    tostring(config.server.port or ''),
  })
  return server
end

---@param project string
---@param server string
---@return string
function M.path(project, server)
  local key = vim.fn.sha256(project .. '\n' .. server)
  return vim.fs.joinpath(vim.fn.stdpath('state'), 'opencode', 'session-tabs', key .. '.json')
end

---Invalid snapshots read as missing, so a bad file never breaks opening the panel.
---@param project string
---@param server string
---@return OpencodeSessionTabSnapshot|nil
function M.load(project, server)
  local file = io.open(M.path(project, server), 'r')
  if not file then
    return nil
  end
  local content = file:read('*a')
  file:close()
  local ok, snapshot = pcall(vim.json.decode, content)
  if not ok or not snapshot_shape:check(snapshot) or snapshot.project ~= project or snapshot.server ~= server then
    return nil
  end
  return snapshot --[[@as OpencodeSessionTabSnapshot]]
end

---Write atomically; readers never see a partially written snapshot.
---@param snapshot OpencodeSessionTabSnapshot
---@return boolean, string|nil
local function write(snapshot)
  local path = M.path(snapshot.project, snapshot.server)
  local temporary = path .. '.' .. vim.fn.getpid() .. '.tmp'
  local ok, err = pcall(function()
    vim.fn.mkdir(vim.fs.dirname(path), 'p')
    assert(vim.fn.writefile({ vim.json.encode(snapshot) }, temporary) == 0, 'Failed to write session tabs')
    assert(os.rename(temporary, path))
  end)
  if not ok then
    os.remove(temporary)
    return false, tostring(err)
  end
  return true
end

---@param key string
---@param group OpencodeTabGroup
---@return boolean
local function save_group(key, group)
  local cwd, server = group.cwd, group.server
  ---@type OpencodeSessionTabSnapshot
  local snapshot = { version = 2, project = group.project, cwd = cwd, server = server, tabs = {}, active_index = 0 }
  for _, runtime in ipairs(tabs.list(key)) do
    local session = runtime.active_session
    if session then
      local directory = runtime.bound_directory or runtime.current_cwd or cwd
      table.insert(snapshot.tabs, {
        session_id = session.id,
        directory = directory,
        bound_directory = runtime.bound_directory,
        session_locked = runtime.session_locked,
      })
      if runtime.id == tabs.selection(key) then
        snapshot.active_index = #snapshot.tabs
      end
    end
  end
  local ok, err = write(snapshot)
  if not ok then
    log.warn('Failed to persist session tabs: ' .. tostring(err))
  end
  return ok
end

---@param current OpencodeSessionTabRuntime[]
---@param background boolean
---@return boolean
local function untouched(current, background)
  return #current == 1 and (background or not current[1].active_session)
end

---@param entry OpencodeSavedSessionTab
---@return boolean
local function directories_exist(entry)
  return vim.fn.isdirectory(entry.directory) == 1
    and (not entry.bound_directory or vim.fn.isdirectory(entry.bound_directory) == 1)
end

---@param snapshot OpencodeSessionTabSnapshot
---@param current OpencodeSessionTabRuntime
---@param cwd string
---@param background boolean
---@param is_current fun(): boolean
local restore_snapshot = Promise.async(function(snapshot, current, cwd, background, is_current)
  local connection = server_job.ensure_server():await()
  if not connection then
    error('Server failed to start')
  end

  -- Each connection owns its matching protocol adapter; both return neutral session facts.
  local lookup = connection.operations.get_session --[[@as OpencodePersistedSessionLookup]]
  ---@type { entry: OpencodeSavedSessionTab, index: integer }[]
  local candidates = {}
  ---@type Promise<OpencodeSession|nil>[]
  local lookups = {}
  local seen = {}
  for index, entry in ipairs(snapshot.tabs) do
    if not seen[entry.session_id] and directories_exist(entry) then
      seen[entry.session_id] = true
      table.insert(candidates, { entry = entry, index = index })
      table.insert(
        lookups,
        lookup(
          connection,
          entry.session_id,
          { directory = entry.directory },
          util.apply_path_map,
          util.apply_reverse_path_map
        ):catch(function()
          return nil
        end)
      )
    end
  end
  local sessions = Promise.all(lookups):await()

  -- Lookups yield; explicit session actions or cwd changes meanwhile take priority.
  local latest = tabs.list()
  if not is_current() or latest[1] ~= current or not untouched(latest, background) then
    return
  end
  local occupied = current.active_session and current.active_session.id
  local restored = {}
  local active
  for i, item in ipairs(candidates) do
    local session = sessions[i]
    if session and session.id ~= occupied then
      local runtime = tabs.create(session)
      runtime.current_cwd = item.entry.directory
      runtime.bound_directory = item.entry.bound_directory
      if item.entry.bound_directory then
        runtime.bound_editor_cwd = cwd
      end
      runtime.session_locked = item.entry.session_locked
      table.insert(restored, runtime)
      if item.index == snapshot.active_index then
        active = runtime
      end
    end
  end
  -- Background restores keep the current tab active for the explicit new session.
  if #restored > 0 and not background then
    tabs.remove(current)
    tabs.activate(active or restored[1])
  end
end)

---@return boolean
function M.is_initialized()
  return owner ~= nil
end

---Resolve the editor project, switch its runtime group, then restore its durable layout once.
---Concurrent opens for the same cwd/server share a request. Newer requests win.
---Never rejects: failures are logged, snapshots stay intact, and the next open retries.
---@param background boolean Explicit new-session opens keep the current tab and append saved tabs behind it.
---@param before_switch? fun() Called before parking outgoing runtime state
---@param directory? string Editor cwd, never a tab's bound directory
---@return Promise<nil>|nil
function M.restore(background, before_switch, directory)
  if not config.ui.restore_tabs_on_startup then
    return nil
  end
  local cwd = vim.fs.normalize(directory or vim.fn.getcwd())
  local server = server_identity()
  if requested_cwd == cwd and requested_server == server and pending_restore and not pending_restore:is_resolved() then
    return pending_restore
  end
  if requested_cwd == cwd and requested_server == server and owner and owner.attempted and not owner.failed then
    return nil
  end
  requested_cwd = cwd
  requested_server = server
  generation = generation + 1
  local request = generation
  ---@type OpencodeTabGroup|nil
  local group
  pending_restore = Promise.async(function()
    local connection = server_job.ensure_server():await()
    if not connection then
      error('Server failed to start')
    end
    local project = connection.operations
      .get_current_project(connection, { directory = cwd }, util.apply_path_map, util.apply_reverse_path_map)
      :await()
    assert(project_shape:check(project), 'Project lookup requires a string id')
    -- OpenCode's global project is shared by unrelated non-VCS directories.
    local identity = project.id
    if identity == '' or identity == 'global' then
      identity = 'directory:' .. cwd
    end
    if request ~= generation then
      return
    end
    local key = M.path(identity, server)
    if not groups[key] then
      groups[key] =
        { project = identity, server = server, cwd = cwd, attempted = false, failed = false, restoring = false }
    end
    group = groups[key]
    ---@type OpencodeTabGroup|nil
    local previous = owner
    if owner ~= group then
      if previous then
        M.save()
        if previous.restoring then
          previous.attempted = false
        end
        if before_switch then
          before_switch()
        end
      end
      tabs.switch_group(key, cwd)
      owner = group
    end
    group.cwd = cwd
    if group.restoring and group.restore_generation ~= request then
      group.attempted = false
    end
    if group.attempted and not group.failed then
      return
    end
    group.attempted = true
    group.failed = false
    local current = tabs.list()
    if not untouched(current, background) then
      return
    end
    local snapshot = M.load(identity, server)
    if not snapshot or #snapshot.tabs == 0 then
      return
    end
    group.restoring = true
    group.restore_generation = request
    restore_snapshot(snapshot, current[1], cwd, background, function()
      return owner == group and request == generation
    end):await()
    if group.restore_generation == request then
      group.restoring = false
      if request ~= generation then
        group.attempted = false
      end
    end
  end)():catch(function(err)
    if group and (not group.restore_generation or group.restore_generation == request) then
      group.failed = true
      group.restoring = false
    end
    if request == generation then
      requested_cwd = nil
    end
    log.warn('Failed to restore session tabs: ' .. tostring(err))
  end)
  return pending_restore
end

---Save only durable session references; never buffers, drafts or permission state.
---Returns false on disk failure (logged), leaving the previous snapshot intact.
---@return boolean
function M.save()
  if not config.ui.restore_tabs_on_startup then
    return true
  end
  local success = true
  for key, group in pairs(groups) do
    if group.attempted and not group.failed and not group.restoring then
      success = save_group(key, group) and success
    end
  end
  return success
end

function M.setup()
  groups = {}
  owner = nil
  generation = generation + 1
  requested_cwd = nil
  requested_server = nil
  pending_restore = nil
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = vim.api.nvim_create_augroup('OpencodeSessionTabPersistence', { clear = true }),
    callback = function()
      M.save()
    end,
  })
end

return M
