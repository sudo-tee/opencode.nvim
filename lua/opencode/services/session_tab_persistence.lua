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
---True while restore replays an on-disk layout into memory; those mutations
---must not bounce back to disk.
local replaying_restore = false
---Debounces persistence after a durable layout change.
---@type uv_timer_t|nil
local save_timer

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

---Last snapshot this process read or wrote per path. A layout that still matches
---it has nothing new to persist, so another instance's newer snapshot is left
---alone.
---@type table<string, OpencodeSessionTabSnapshot>
local synced = {}

---Invalid snapshots read as missing, so a bad file never breaks opening the panel.
---@param project string
---@param server string
---@return OpencodeSessionTabSnapshot|nil
local function read_snapshot(project, server)
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

---@param project string
---@param server string
---@return OpencodeSessionTabSnapshot|nil
function M.load(project, server)
  local snapshot = read_snapshot(project, server)
  if snapshot then
    synced[M.path(project, server)] = snapshot
  end
  return snapshot
end

---Write atomically; readers never see a partially written snapshot.
---@param snapshot OpencodeSessionTabSnapshot
---@param reason string
---@return boolean, string|nil
local function write(snapshot, reason)
  local path = M.path(snapshot.project, snapshot.server)
  local encoded = vim.json.encode(snapshot)
  if synced[path] and vim.deep_equal(synced[path], snapshot) then
    return true
  end
  local temporary = path .. '.' .. vim.fn.getpid() .. '.tmp'
  local ok, err = pcall(function()
    vim.fn.mkdir(vim.fs.dirname(path), 'p')
    assert(vim.fn.writefile({ encoded }, temporary) == 0, 'Failed to write session tabs')
    if vim.fn.has('win32') == 1 then
      os.remove(path)
    end
    assert(os.rename(temporary, path))
  end)
  if not ok then
    os.remove(temporary)
    return false, tostring(err)
  end
  synced[path] = snapshot
  local ids = {}
  for _, tab in ipairs(snapshot.tabs) do
    table.insert(ids, tab.session_id)
  end
  log.debug('session tabs written for %s: %s active_index=%d', reason, table.concat(ids, ','), snapshot.active_index)
  return true
end

---@param key string
---@param group OpencodeTabGroup
---@param reason string
---@return boolean
local function save_group(key, group, reason)
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
  if group.failed then
    local disk = read_snapshot(group.project, server)
    if disk then
      local merged = { version = 2, project = group.project, cwd = cwd, server = server, tabs = {}, active_index = 0 }
      local seen = {}
      for _, tab in ipairs(disk.tabs) do
        seen[tab.session_id] = true
        table.insert(merged.tabs, tab)
      end
      local our_active
      for index, tab in ipairs(snapshot.tabs) do
        if not seen[tab.session_id] then
          seen[tab.session_id] = true
          table.insert(merged.tabs, tab)
        end
        if index == snapshot.active_index then
          our_active = tab.session_id
        end
      end
      for index, tab in ipairs(merged.tabs) do
        if tab.session_id == our_active then
          merged.active_index = index
        end
      end
      if merged.active_index == 0 then
        merged.active_index = math.min(snapshot.active_index, #merged.tabs)
      end
      snapshot = merged
    end
  end
  local ok, err = write(snapshot, reason)
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
        ):catch(function(err)
          log.warn('session lookup failed for %s: %s', entry.session_id, tostring(err))
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
    replaying_restore = true
    if save_timer then
      save_timer:stop()
    end
    local ok, err = pcall(function()
      tabs.remove(current)
      tabs.activate(active or restored[1])
    end)
    vim.schedule(function()
      replaying_restore = false
    end)
    if not ok then
      error(err)
    end
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
    log.debug('restore skip: restore_tabs_on_startup is off')
    return nil
  end
  local cwd = vim.fs.normalize(directory or vim.fn.getcwd())
  local server = server_identity()
  if requested_cwd == cwd and requested_server == server and pending_restore and not pending_restore:is_resolved() then
    log.debug('restore reuse: pending request', { cwd = cwd })
    return pending_restore
  end
  if requested_cwd == cwd and requested_server == server and owner and owner.attempted and not owner.failed then
    log.debug('restore skip: group already attempted', { cwd = cwd })
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
        M.save('group switch')
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
      log.debug('restore skip: group attempted inside promise', { key = key })
      return
    end
    group.attempted = true
    group.failed = false
    local current = tabs.list()
    if not untouched(current, background) then
      log.debug('restore skip: current tab is no longer untouched', { tabs = #current })
      return
    end
    local snapshot = M.load(identity, server)
    if not snapshot or #snapshot.tabs == 0 then
      log.debug('restore skip: no snapshot', { key = key, identity = identity })
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
---@param reason? string Why the snapshot is being written; lands in the debug log.
---@return boolean
function M.save(reason)
  reason = reason or 'manual'
  if not config.ui.restore_tabs_on_startup then
    return true
  end
  local success = true
  for key, group in pairs(groups) do
    if not group.restoring then
      local healthy = group.attempted and not group.failed
      local has_live = false
      for _, runtime in ipairs(tabs.list(key)) do
        if runtime.active_session then
          has_live = true
          break
        end
      end
      -- An empty state still saves, so closed tabs do not resurrect; a failed restore saves only
      -- once the user holds sessions, so it cannot blank a good snapshot.
      if healthy or has_live then
        success = save_group(key, group, reason) and success
      end
    end
  end
  return success
end

---Persist the current layout soon after a durable change (session switch, tab
---open/close). Exit-only saving loses everything when the instance that holds
---the real work stays open while other instances keep writing stale layouts.
local pending_reason = 'change'

---@param key? string Store key that changed.
local function schedule_save(key)
  pending_reason = key and ('change ' .. key) or 'change'
  if replaying_restore then
    return
  end
  if not save_timer then
    save_timer = vim.uv.new_timer()
  end
  save_timer:stop()
  save_timer:start(
    300,
    0,
    vim.schedule_wrap(function()
      if not owner then
        return
      end
      M.save(pending_reason)
    end)
  )
end

function M.setup()
  groups = {}
  owner = nil
  generation = generation + 1
  requested_cwd = nil
  requested_server = nil
  pending_restore = nil
  replaying_restore = false
  synced = {}
  if save_timer then
    save_timer:stop()
  end
  local store = require('opencode.state.store')
  store.subscribe({ 'active_session', 'session_tabs_changed' }, schedule_save)
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = vim.api.nvim_create_augroup('OpencodeSessionTabPersistence', { clear = true }),
    callback = function()
      M.save('exit')
    end,
  })
end

return M
