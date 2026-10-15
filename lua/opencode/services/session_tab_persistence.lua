local config = require('opencode.config')
local tabs = require('opencode.state.session_tabs')
local server_job = require('opencode.server_job')
local Promise = require('opencode.promise')
local util = require('opencode.util')
local log = require('opencode.log')
local v = require('opencode.shape')

local M = {}
local attempted = false
---@type Promise<nil>|nil
local pending_restore
-- A failed restore must neither overwrite the snapshot on exit nor block a later retry.
local restore_failed = false

---@class OpencodeSavedSessionTab
---@field session_id string
---@field directory string
---@field bound_directory? string
---@field session_locked? boolean

---@class OpencodeSessionTabSnapshot
---@field version integer
---@field cwd string
---@field server string
---@field tabs OpencodeSavedSessionTab[]
---@field active_index integer

-- The snapshot file is external input: it may be corrupt or hand-edited.
local snapshot_shape = v.object({
  version = v.literal(1),
  cwd = 'string',
  server = 'string',
  active_index = v.integer(),
  tabs = v.array(v.object({
    session_id = 'string',
    directory = 'string',
    bound_directory = v.optional('string'),
    session_locked = v.optional('boolean'),
  })),
})

---@alias OpencodePersistedSessionLookup fun(connection: OpencodeV1Connection|OpencodeV2Connection, session_id: string, location: OpencodeLocation, path_map: OpencodePathMap, reverse_path_map: OpencodePathMap): Promise<OpencodeSession>

---@return string, string
local function workspace()
  local cwd = vim.fs.normalize(vim.fn.getcwd())
  -- Use configured identity, not a discovered/random port that changes on restart.
  local server = vim.json.encode({
    config.opencode_executable,
    config.server.url or '',
    tostring(config.server.port or ''),
  })
  return cwd, server
end

---@param cwd string
---@param server string
---@return string
function M.path(cwd, server)
  local key = vim.fn.sha256(cwd .. '\n' .. server)
  return vim.fs.joinpath(vim.fn.stdpath('state'), 'opencode', 'session-tabs', key .. '.json')
end

---Invalid snapshots read as missing, so a bad file never breaks opening the panel.
---@param cwd string
---@param server string
---@return OpencodeSessionTabSnapshot|nil
function M.load(cwd, server)
  local file = io.open(M.path(cwd, server), 'r')
  if not file then
    return nil
  end
  local content = file:read('*a')
  file:close()
  local ok, snapshot = pcall(vim.json.decode, content)
  -- cwd/server are re-checked to reject sha256 path collisions.
  if not ok or not snapshot_shape:check(snapshot) or snapshot.cwd ~= cwd or snapshot.server ~= server then
    return nil
  end
  return snapshot --[[@as OpencodeSessionTabSnapshot]]
end

---Write atomically; readers never see a partially written snapshot.
---@param snapshot OpencodeSessionTabSnapshot
---@return boolean, string|nil
local function write(snapshot)
  local path = M.path(snapshot.cwd, snapshot.server)
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
local restore_snapshot = Promise.async(function(snapshot, current, cwd, background)
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
  if latest[1] ~= current or not untouched(latest, background) or workspace() ~= cwd then
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

---Restore once into an untouched tab registry, without mounting windows.
---Returns nil when there is nothing to wait for, so callers keep their normal open order.
---Concurrent opens share the same restore rather than mounting half-loaded state.
---Never rejects: failures are logged, fall back to ordinary session selection and retry on the next open.
---@param background boolean Explicit new-session opens keep the current tab and append saved tabs behind it.
---@return Promise<nil>|nil
function M.restore(background)
  if pending_restore then
    if not pending_restore:is_resolved() then
      return pending_restore
    end
    if not restore_failed then
      return nil
    end
    pending_restore = nil
    attempted = false
    restore_failed = false
  end
  if attempted or not config.ui.restore_tabs_on_startup then
    return nil
  end
  attempted = true
  local current = tabs.list()
  if not untouched(current, background) then
    return nil
  end
  local cwd, server = workspace()
  local snapshot = M.load(cwd, server)
  if not snapshot or #snapshot.tabs == 0 then
    return nil
  end
  pending_restore = restore_snapshot(snapshot, current[1], cwd, background):catch(function(err)
    restore_failed = true
    log.warn('Failed to restore session tabs: ' .. tostring(err))
  end)
  return pending_restore
end

---Save only durable session references; never buffers, drafts or permission state.
---Returns false on disk failure (logged), leaving the previous snapshot intact.
---@return boolean
function M.save()
  if
    not config.ui.restore_tabs_on_startup
    or not attempted
    or restore_failed
    or (pending_restore and not pending_restore:is_resolved())
  then
    return true
  end
  local cwd, server = workspace()
  ---@type OpencodeSessionTabSnapshot
  local snapshot = { version = 1, cwd = cwd, server = server, tabs = {}, active_index = 0 }
  for _, runtime in ipairs(tabs.list()) do
    local session = runtime.active_session
    if session then
      local directory = runtime.bound_directory or runtime.current_cwd or cwd
      table.insert(snapshot.tabs, {
        session_id = session.id,
        directory = directory,
        bound_directory = runtime.bound_directory,
        session_locked = runtime.session_locked,
      })
      if runtime.id == tabs.active_id() then
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

function M.setup()
  attempted = false
  pending_restore = nil
  restore_failed = false
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = vim.api.nvim_create_augroup('OpencodeSessionTabPersistence', { clear = true }),
    callback = function()
      M.save()
    end,
  })
end

return M
