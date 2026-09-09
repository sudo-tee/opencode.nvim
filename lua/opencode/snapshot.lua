-- This file is a port of the snapshot management logic from the original OpenCode
---@see https://github.com/sst/opencode/blob/dev/packages/opencode/src/snapshot/index.ts

---@class OpencodeSnapshot
---@field track fun(): Promise<string|nil>
---@field create fun(): Promise<string|nil>
---@field patch fun(hash: string): Promise<OpencodeSnapshotPatch|nil>
---@field diff fun(hash: string): Promise<string|nil>
---@field diff_file fun(hash: string, file: string): Promise<{left: string, right: string, file_type: string}>
---@field revert fun(hash: string): Promise<{id: string, deleted_files: string[]}|nil>
---@field revert_file fun(hash: string, file: string): Promise<{id: string, deleted_files: string[]}|nil>
---@field restore fun(hash: string): Promise<boolean|nil>
---@field restore_file fun(hash: string, file: string): Promise<boolean|nil>
---@field save_restore_point fun(hash: string, parent?: string, deleted_files?: string[]): Promise<RestorePoint|nil>
local M = {}
local operations = {}
local state = require('opencode.state')
local util = require('opencode.util')
local config_file = require('opencode.config_file')
local session = require('opencode.session')
local Promise = require('opencode.promise')

local contexts = setmetatable({}, { __mode = 'k' })
local pending = {}

local function operation_context()
  return assert(contexts[coroutine.running()], 'Snapshot operation requires an async context')
end

local function canonical_path(path)
  local normalized = vim.fs.normalize(path)
  local resolved = vim.fn.resolve(normalized)
  return resolved ~= '' and vim.fs.normalize(resolved) or normalized
end

---@param cmd_args string[]
---@param opts? vim.SystemOpts
---@return string|nil, string|nil
local function snapshot_git(cmd_args, opts)
  local context = operation_context()
  local args = { 'git', '--git-dir', context.snapshot_dir, '--work-tree', context.cwd }
  vim.list_extend(args, cmd_args)
  local ok, result = pcall(function()
    return Promise.system(args, vim.tbl_extend('force', opts or {}, { cwd = context.cwd })):await()
  end)
  if ok then
    return result.stdout or '', nil
  end
  return nil, type(result) == 'table' and result.stderr or tostring(result)
end

local function relative_path(file)
  local cwd = operation_context().cwd
  local absolute = canonical_path(file:sub(1, 1) == '/' and file or vim.fs.joinpath(cwd, file))
  local prefix = cwd:gsub('/$', '') .. '/'
  if absolute:sub(1, #prefix) ~= prefix then
    error('Snapshot file is outside the captured workspace: ' .. file)
  end
  return absolute:sub(#prefix + 1)
end

local function checkout_or_delete(snapshot_id, file, deleted_files)
  local relative = relative_path(file)
  local present, lookup_error = snapshot_git({ 'ls-tree', '--name-only', snapshot_id, '--', relative })
  if not present then
    error('Failed to inspect snapshot: ' .. (lookup_error or 'unknown error'))
  end
  if present ~= '' then
    local result, err = snapshot_git({ 'checkout', snapshot_id, '--', relative })
    if not result then
      error('Failed to checkout file: ' .. (err or 'unknown error'))
    end
  else
    local absolute = operation_context().cwd .. '/' .. relative
    if vim.fn.delete(absolute) ~= 0 and vim.uv.fs_stat(absolute) then
      error('Failed to delete file: ' .. absolute)
    end
    deleted_files[#deleted_files + 1] = absolute
  end
end

local function write_to_temp_file(content)
  local temp_file = vim.fn.tempname()
  local f = io.open(temp_file, 'w')
  if not f then
    vim.notify('Failed to open temp file: ' .. temp_file)
    return nil
  end
  f:write(content)
  f:close()
  return temp_file
end

function operations.track()
  if not operation_context().session then
    vim.notify('No active session', vim.log.levels.ERROR)
    return nil
  end

  local _, add_err = snapshot_git({ 'add', '.' })
  if add_err then
    error('Failed to add files: ' .. add_err)
  end

  local hash_output, write_tree_err = snapshot_git({ 'write-tree' })
  if not hash_output then
    vim.notify('Failed to write tree: ' .. (write_tree_err or 'unknown error'), vim.log.levels.ERROR)
    return nil
  end

  return vim.trim(hash_output)
end

function operations.create()
  return M.track():await()
end

function operations.save_restore_point(snapshot_id, from_snapshot_id, deleted_files)
  if not operation_context().session then
    vim.notify('No active session', vim.log.levels.ERROR)
    return nil
  end

  local context = operation_context()
  local cache_path = session.get_cache_path(context.session.id)
  local patch_result = M.patch(snapshot_id):await()
  local snapshot = {
    id = snapshot_id,
    from_snapshot_id = from_snapshot_id or nil,
    files = patch_result and patch_result.files or {},
    deleted_files = deleted_files or {},
    created_at = os.time(),
  }

  local path = cache_path .. 'snapshots/'
  if vim.fn.isdirectory(path) == 0 then
    vim.fn.mkdir(path, 'p')
  end

  local snapshot_file = path .. snapshot_id .. '.json'
  local ok, err = pcall(vim.fn.writefile, { vim.json.encode(snapshot) }, snapshot_file)
  if not ok then
    vim.notify('Failed to write restore point: ' .. err, vim.log.levels.ERROR)
    return nil
  end

  if state.active_session == context.session and state.event_manager then
    state.event_manager:emit('custom.restore_point.created', { restore_point = snapshot })
  end
  return snapshot
end

---@return RestorePoint[]
function M.get_restore_points()
  if not state.active_session then
    state.session.reset_restore_points()
    return {}
  end
  local cache_path = session.get_cache_path(state.active_session.id)
  if not cache_path then
    return {}
  end
  if state.restore_points and #state.restore_points > 0 then
    return state.restore_points
  end
  local restore_points = util.read_json_dir(cache_path .. 'snapshots/') or {}
  table.sort(restore_points, function(a, b)
    return a.created_at > b.created_at
  end)
  state.session.set_restore_points(restore_points)
  return state.restore_points
end

---@return OpencodeSnapshotPatch|nil
function operations.patch(hash)
  if not operation_context().session then
    vim.notify('No active session', vim.log.levels.ERROR)
    return nil
  end

  local _, add_err = snapshot_git({ 'add', '.' })
  if add_err then
    error('Failed to add files: ' .. add_err)
  end

  local files_output, diff_err =
    snapshot_git({ 'diff', '--cached', '--no-ext-diff', '--name-only', '-z', hash, '--', '.' })
  if not files_output then
    vim.notify('Failed to get diff: ' .. (diff_err or 'unknown error'), vim.log.levels.ERROR)
    return nil
  end

  local files = {}
  local cwd = operation_context().cwd
  for file in files_output:gmatch('[^%z]+') do
    table.insert(files, cwd .. '/' .. file)
  end

  return {
    hash = hash,
    files = files,
  }
end

function operations.diff(hash)
  if not operation_context().session then
    vim.notify('No active session', vim.log.levels.ERROR)
    return nil
  end

  local result, err = snapshot_git({ 'diff', '--cached', '--no-ext-diff', hash, '--', '.' })
  if not result then
    vim.notify('Failed to get diff: ' .. (err or 'unknown error'), vim.log.levels.ERROR)
    return nil
  end

  return vim.trim(result)
end

function operations.diff_file(snapshot_id, file_path)
  local path = relative_path(file_path)
  local file_at_snapshot = snapshot_git({ 'show', snapshot_id .. ':' .. path })
  local temp_file = write_to_temp_file(file_at_snapshot or '')
  local file_type = vim.fn.fnamemodify(file_path, ':e')
  return { left = file_path, right = temp_file, file_type = file_type }
end

function operations.revert(snapshot_id)
  local restore_point_id = M.create():await()
  if not restore_point_id then
    error('Failed to create restore point')
  end
  local patch_result = M.patch(snapshot_id):await()
  if not patch_result then
    vim.notify('Failed to revert snapshot: ' .. snapshot_id, vim.log.levels.ERROR)
    return
  end
  local deleted_files = {}
  for _, file in ipairs(patch_result.files) do
    checkout_or_delete(snapshot_id, file, deleted_files)
  end
  vim.cmd('checktime')
  M.save_restore_point(restore_point_id, snapshot_id, deleted_files):await()
  return { id = restore_point_id, deleted_files = deleted_files }
end

---@param snapshot_id string
---@param file_path string
---@return string|nil, string[]
function operations.revert_file(snapshot_id, file_path)
  local restore_point_id = M.create():await()
  if not restore_point_id then
    error('Failed to create restore point')
  end
  local deleted_files = {}
  checkout_or_delete(snapshot_id, file_path, deleted_files)
  vim.cmd('checktime')
  M.save_restore_point(restore_point_id, snapshot_id, deleted_files):await()
  return { id = restore_point_id, deleted_files = deleted_files }
end

---@param snapshot_id string
function operations.restore(snapshot_id)
  local read_tree_out, read_tree_err = snapshot_git({ 'read-tree', snapshot_id })
  if not read_tree_out then
    vim.notify('Failed to read-tree: ' .. (read_tree_err or 'unknown error'), vim.log.levels.ERROR)
    return
  end

  local checkout_out, checkout_err = snapshot_git({ 'checkout-index', '-a', '-f' })
  if not checkout_out then
    vim.notify('Failed to checkout-index: ' .. (checkout_err or 'unknown error'), vim.log.levels.ERROR)
    return
  end

  vim.notify('Restored snapshot: ' .. snapshot_id, vim.log.levels.INFO)
  return true
end

function operations.restore_file(snapshot_id, file_path)
  local read_tree_out, read_tree_err = snapshot_git({ 'read-tree', snapshot_id })
  if not read_tree_out then
    vim.notify('Failed to read-tree: ' .. (read_tree_err or 'unknown error'), vim.log.levels.ERROR)
    return
  end

  local checkout_out, checkout_err = snapshot_git({ 'checkout-index', '-f', '--', relative_path(file_path) })
  if not checkout_out then
    vim.notify('Failed to checkout-index: ' .. (checkout_err or 'unknown error'), vim.log.levels.ERROR)
    return
  end

  vim.notify('Restored file: ' .. file_path .. ' from snapshot: ' .. snapshot_id, vim.log.levels.INFO)
  return true
end

---@param from_snapshot_id string
---@return RestorePoint[]|nil
function M.get_restore_points_by_parent(from_snapshot_id)
  local restore_points = M.get_restore_points()
  restore_points = vim.tbl_filter(function(item)
    return item.from_snapshot_id == from_snapshot_id
  end, restore_points)
  table.sort(restore_points, function(a, b)
    return a.created_at > b.created_at
  end)
  if #restore_points == 0 then
    return nil
  end
  return restore_points
end

---Run a snapshot operation against the session and directory captured at invocation.
---Nested operations share the same context and index lock.
---@generic T
---@param fn fun(): T
---@param captured? {cwd: string, session: Session|nil}
---@return Promise<T>
function M.with_context(fn, captured)
  local inherited = coroutine.running() and contexts[coroutine.running()]
  local context = inherited or captured or { cwd = vim.fn.getcwd(), session = state.active_session }
  if not inherited then
    context.cwd = canonical_path(context.cwd)
  end
  return Promise.spawn(function()
    local co = coroutine.running()
    contexts[co] = context
    local release
    local ok, result = pcall(function()
      if not inherited then
        if not context.session then
          error('No active session found.')
        end
        context.snapshot_dir = config_file.get_workspace_snapshot_path(context.cwd):await()
        if not context.snapshot_dir or context.snapshot_dir == '' then
          error('No snapshot path for the active session.')
        end
        local previous = pending[context.snapshot_dir]
        release = Promise.new()
        pending[context.snapshot_dir] = release
        if previous then
          previous:await()
        end
      end
      return fn()
    end)
    contexts[co] = nil
    if release then
      if pending[context.snapshot_dir] == release then
        pending[context.snapshot_dir] = nil
      end
      release:resolve(true)
    end
    if not ok then
      error(result)
    end
    return result
  end)
end

for _, name in ipairs({
  'track',
  'create',
  'save_restore_point',
  'patch',
  'diff',
  'diff_file',
  'revert',
  'revert_file',
  'restore',
  'restore_file',
}) do
  local operation = operations[name]
  M[name] = function(...)
    local args, count = { ... }, select('#', ...)
    return M.with_context(function()
      return operation(unpack(args, 1, count))
    end)
  end
end

return M
