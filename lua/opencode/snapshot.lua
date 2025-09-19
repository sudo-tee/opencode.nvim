-- This file is a port of the snapshot management logic from the original OpenCode
--- @see https://github.com/sst/opencode/blob/dev/packages/opencode/src/snapshot/index.ts

local M = {}
local state = require('opencode.state')
local util = require('opencode.util')

---@param cmd_args string[]
---@param opts? vim.SystemOpts
---@return string|nil, string|nil
local function snapshot_git(cmd_args, opts)
  local snapshot_dir = state.active_session and state.active_session.snapshot_path
  if not snapshot_dir then
    vim.notify('No snapshot path for the active session.')
    return nil, nil
  end
  local args = { 'git', '-C', snapshot_dir }
  vim.list_extend(args, cmd_args)
  local result = vim.system(args, opts or {}):wait()
  if result and result.code == 0 then
    return vim.trim(result.stdout), nil
  else
    return nil, result and result.stderr or nil
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

function M.track()
  if not state.active_session then
    vim.notify('No active session', vim.log.levels.ERROR)
    return nil
  end

  local snapshot_dir = state.active_session.snapshot_path
  if not snapshot_dir then
    vim.notify('No snapshot path for the active session.')
    return nil
  end

  local _, add_err = snapshot_git({ 'add', '.' })
  if add_err then
    vim.notify('Failed to add files: ' .. add_err, vim.log.levels.WARN)
  end

  local hash_output, write_tree_err = snapshot_git({ 'write-tree' })
  if not hash_output then
    vim.notify('Failed to write tree: ' .. (write_tree_err or 'unknown error'), vim.log.levels.ERROR)
    return nil
  end

  return vim.trim(hash_output)
end

function M.create()
  return M.track()
end

function M.save_restore_point(snapshot_id, from_snapshot_id, deleted_files)
  if not state.active_session then
    vim.notify('No active session', vim.log.levels.ERROR)
    return nil
  end

  local patch_result = M.patch(snapshot_id)
  local snapshot = {
    id = snapshot_id,
    from_snapshot_id = from_snapshot_id or nil,
    files = patch_result and patch_result.files or {},
    deleted_files = deleted_files or {},
    created_at = os.time(),
  }

  local path = state.active_session.cache_path .. 'snapshots/'
  if vim.fn.isdirectory(path) == 0 then
    vim.fn.mkdir(path, 'p')
  end

  local snapshot_file = path .. snapshot_id .. '.json'
  local ok, err = pcall(vim.fn.writefile, { vim.json.encode(snapshot) }, snapshot_file)
  if not ok then
    vim.notify('Failed to write restore point: ' .. err, vim.log.levels.ERROR)
    return nil
  end

  state.append('restore_points', snapshot)
  return snapshot
end

---@return RestorePoint[]
function M.get_restore_points()
  if not state.active_session then
    state.restore_points = {}
    return {}
  end
  if not state.active_session.cache_path then
    return {}
  end
  if state.restore_points and #state.restore_points > 0 then
    return state.restore_points
  end
  local restore_points = util.read_json_dir(state.active_session.cache_path .. 'snapshots/') or {}
  table.sort(restore_points, function(a, b)
    return a.created_at > b.created_at
  end)
  state.restore_points = restore_points
  return state.restore_points
end

---@return OpencodeSnapshotPatch|nil
function M.patch(hash)
  if not state.active_session then
    vim.notify('No active session', vim.log.levels.ERROR)
    return nil
  end

  local _, add_err = snapshot_git({ 'add', '.' })
  if add_err then
    vim.notify('Failed to add files: ' .. add_err .. _, vim.log.levels.WARN)
  end

  local files_output, diff_err = snapshot_git({ 'diff', '--name-only', hash, '--', '.' })
  if not files_output then
    vim.notify('Failed to get diff: ' .. (diff_err or 'unknown error'), vim.log.levels.ERROR)
    return nil
  end

  local files = {}
  local cwd = vim.fn.getcwd()
  for line in files_output:gmatch('[^\r\n]+') do
    local trimmed = vim.trim(line)
    if trimmed ~= '' then
      table.insert(files, cwd .. '/' .. trimmed)
    end
  end

  return {
    hash = hash,
    files = files,
  }
end

function M.diff(hash)
  if not state.active_session then
    vim.notify('No active session', vim.log.levels.ERROR)
    return nil
  end

  local result, err = snapshot_git({ 'diff', hash, '--', '.' })
  if not result then
    vim.notify('Failed to get diff: ' .. (err or 'unknown error'), vim.log.levels.ERROR)
    return nil
  end

  return vim.trim(result)
end

function M.diff_file(snapshot_id, file_path)
  local relative_path = vim.fn.fnamemodify(file_path, ':.')
  local file_at_snapshot = snapshot_git({ 'show', snapshot_id .. ':' .. relative_path })
  local temp_file = write_to_temp_file(file_at_snapshot or '')
  local file_type = vim.fn.fnamemodify(file_path, ':e')
  return { left = file_path, right = temp_file, file_type = file_type }
end

function M.revert(snapshot_id)
  local restore_point_id = M.create()
  local patch_result = M.patch(snapshot_id)
  if not patch_result then
    vim.notify('Failed to revert snapshot: ' .. snapshot_id, vim.log.levels.ERROR)
    return
  end
  local deleted_files = {}
  for _, file in ipairs(patch_result.files) do
    local relative_path = file:match('^' .. vim.fn.getcwd() .. '/?(.*)$')
    local res, err = snapshot_git({ 'checkout', snapshot_id, '--', relative_path })
    if not res then
      vim.notify(
        'file not found in history, deleting: ' .. file .. ' - ' .. (err or 'unknown error'),
        vim.log.levels.WARN
      )
      vim.fn.delete(file)
      table.insert(deleted_files, file)
    end
    vim.cmd('checktime')
  end
  M.save_restore_point(restore_point_id, snapshot_id, deleted_files)
  return restore_point_id, deleted_files
end

---@param snapshot_id string
---@param file_path string
---@return string|nil, string[]
function M.revert_file(snapshot_id, file_path)
  local restore_point_id = M.create()
  local relative_path = vim.fn.fnamemodify(file_path, ':.')
  local res, err = snapshot_git({ 'checkout', snapshot_id, '--', relative_path })
  local deleted_files = {}

  if not res then
    vim.notify(
      'file not found in history, deleting: ' .. file_path .. ' - ' .. (err or 'unknown error'),
      vim.log.levels.WARN
    )
    vim.fn.delete(file_path)
    table.insert(deleted_files, file_path)
  end
  vim.cmd('checktime')
  M.save_restore_point(restore_point_id, snapshot_id, deleted_files)
  return restore_point_id, deleted_files
end

---@param snapshot_id string
function M.restore(snapshot_id)
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
end

function M.restore_file(snapshot_id, file_path)
  local read_tree_out, read_tree_err = snapshot_git({ 'read-tree', snapshot_id })
  if not read_tree_out then
    vim.notify('Failed to read-tree: ' .. (read_tree_err or 'unknown error'), vim.log.levels.ERROR)
    return
  end

  local checkout_out, checkout_err = snapshot_git({ 'checkout-index', '-f', '--', file_path })
  if not checkout_out then
    vim.notify('Failed to checkout-index: ' .. (checkout_err or 'unknown error'), vim.log.levels.ERROR)
    return
  end

  vim.notify('Restored file: ' .. file_path .. ' from snapshot: ' .. snapshot_id, vim.log.levels.INFO)
end

---@param from_snapshot_id string
---@return RestorePoint[]
function M.get_restore_points_by_parent(from_snapshot_id)
  local restore_points = M.get_restore_points()
  restore_points = vim.tbl_filter(function(item)
    return item.from_snapshot_id == from_snapshot_id
  end, restore_points)
  table.sort(restore_points, function(a, b)
    return a.created_at > b.created_at
  end)
  return restore_points
end

return M
