local Path = require('plenary.path')
local state = require('opencode.state')
local snapshot = require('opencode.snapshot')
local diff_tab = require('opencode.ui.diff_tab')
local utils = require('opencode.util')
local session = require('opencode.session')

local M = {}

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
    return vim.trim(result.stdout), result.stderr
  else
    return nil, result and result.stderr or nil
  end
end

M.__changed_files = nil
M.__current_file_index = nil
M.__diff_tab = nil
M.__current_ref = nil
M.__last_ref = nil

local git = {
  is_project = function()
    if M.__is_git_project ~= nil then
      return M.__is_git_project
    end

    local git_dir = Path:new(vim.fn.getcwd()):joinpath('.git')
    M.__is_git_project = git_dir:exists() and git_dir:is_dir()

    return M.__is_git_project
  end,

  list_changed_files = function()
    if not M.__current_ref then
      return {}
    end
    local patch = snapshot.patch(M.__current_ref)
    return patch and patch.files or {}
  end,

  is_tracked = function(file_path)
    local out = snapshot_git({ 'ls-files', '--error-unmatch', file_path })
    return out ~= nil
  end,
}

---@generic T
---@param fn T
---@param silent any
---@return T
local function require_git_project(fn, silent)
  return function(...)
    if not git.is_project() then
      if not silent then
        vim.notify('Error: Not in a git project.')
      end
      return
    end
    if not state.active_session then
      if not silent then
        vim.notify('Error: No active session found.')
      end
      return
    end
    if not state.active_session.snapshot_path or vim.fn.isdirectory(state.active_session.snapshot_path) == 0 then
      if not silent then
        vim.notify('Error: No snapshot path for the active session.')
      end
      return
    end
    return fn(...)
  end
end

local function get_changed_files(ref)
  local files = {}

  local git_files = git.list_changed_files()

  for _, file in ipairs(git_files) do
    if file ~= '' then
      table.insert(files, snapshot.diff_file(ref or M.__current_ref, file))
    end
  end

  M.__changed_files = files

  return files
end

local function display_file_at_index(idx)
  local file_data = M.__changed_files[idx]
  local file_name = vim.fn.fnamemodify(file_data.left, ':t')
  vim.notify(string.format('Showing file %d of %d: %s', idx, #M.__changed_files, file_name))
  diff_tab.open_diff_tab(file_data.left, file_data.right, file_data.file_type)
end

---@param rev string
---@param n? number|string
---@return string|nil
local function get_git_rev(rev, n)
  if n and type(n) ~= 'number' then
    return nil
  end
  if n == 0 or n == nil then
    return snapshot_git({ 'rev-parse', rev })
  elseif n < 0 then
    return snapshot_git({ 'rev-parse', string.format('%s~%d', rev, math.abs(n)) })
  end
  return nil
end

M.get_first_snapshot = require_git_project(function()
  if not state.active_session then
    vim.notify('No active session found.')
    return nil
  end

  for _, msg in ipairs(state.messages or {}) do
    local snapshots = session.get_message_snapshot_ids(msg)
    if snapshots and #snapshots > 0 then
      return snapshots[1]
    end
  end
end)

M.review = require_git_project(function(ref)
  M.__current_ref = ref or M.get_first_snapshot()
  local files = get_changed_files()

  if #files == 0 then
    vim.notify('No changes to review.')
    return
  end

  if #files == 1 then
    M.__current_file_index = 1
    diff_tab.open_diff_tab(files[1].left, files[1].right, files[1].file_type)
  else
    vim.ui.select(
      vim.tbl_map(function(f)
        return vim.fn.fnamemodify(f.left, ':.')
      end, files),
      { prompt = 'Select a file to review:' },
      function(choice, idx)
        if not choice then
          return
        end
        M.__current_file_index = idx

        diff_tab.open_diff_tab(files[idx].left, files[idx].right, files[idx].file_type)
      end
    )
  end
end)

M.next_diff = require_git_project(function(ref, last_ref)
  M.__current_ref = ref or M.get_first_snapshot()
  M.__last_ref = last_ref and get_git_rev(ref, last_ref) or 'HEAD'
  if not M.__changed_files or not M.__current_file_index or M.__current_file_index >= #M.__changed_files then
    local files = get_changed_files()
    if #files == 0 then
      vim.notify('No changes to review.')
      return
    end
    M.__changed_files = files
    M.__current_file_index = 1
  else
    M.__current_file_index = M.__current_file_index + 1
  end

  display_file_at_index(M.__current_file_index)
end)

M.prev_diff = require_git_project(function(ref, last_ref)
  M.__current_ref = ref or M.get_first_snapshot()
  M.__last_ref = last_ref and get_git_rev(ref, last_ref) or 'HEAD'
  if not M.__changed_files or #M.__changed_files == 0 then
    local files = get_changed_files()
    if #files == 0 then
      vim.notify('No changes to review.')
      return
    end
    M.__current_file_index = #files
  else
    if not M.__current_file_index or M.__current_file_index <= 1 then
      M.__current_file_index = #M.__changed_files
    else
      M.__current_file_index = M.__current_file_index - 1
    end
  end

  display_file_at_index(M.__current_file_index)
end)

M.revert_current = require_git_project(
  ---@param current_ref? string|nil
  ---@param last_ref? string|nil
  function(current_ref, last_ref)
    M.__current_ref = current_ref or M.get_first_snapshot()

    local files = get_changed_files()
    local current_file = vim.fn.expand('%:p')
    local abs_path = vim.fn.fnamemodify(current_file, ':p')

    local changed_file = nil
    for _, file_data in ipairs(files) do
      if file_data[1] == abs_path then
        changed_file = file_data
        break
      end
    end

    if not changed_file then
      vim.notify('No changes to revert.')
      return
    end

    if vim.fn.input('Revert current file? (y/n): '):lower() ~= 'y' then
      return
    end

    if M.revert_file(changed_file[1], current_ref) then
      vim.cmd('e!')
      vim.cmd('checktime')
    end
  end
)

M.revert_file = require_git_project(function(file_path, ref)
  snapshot.revert_file(ref, file_path)
end)

M.revert_selected_file = require_git_project(function(ref)
  M.__current_ref = ref or M.get_first_snapshot()

  local files = get_changed_files()

  if #files == 0 then
    vim.notify('No changes to revert.')
    return
  end

  if #files == 1 then
    if M.revert_file(files[1].left, ref) then
      vim.cmd('checktime')
    end
    return
  end

  vim.ui.select(
    vim.tbl_map(function(f)
      return vim.fn.fnamemodify(f.left, ':.')
    end, files),
    { prompt = 'Select a file to revert:' },
    function(choice, idx)
      if not choice then
        return
      end
      local file_data = files[idx]
      if M.revert_file(file_data.left, ref) then
        vim.cmd('checktime')
      end
    end
  )
end)

M.revert_all = require_git_project(function(ref)
  M.__current_ref = ref or M.get_first_snapshot()

  local files = get_changed_files()

  if #files == 0 then
    vim.notify('No changes to revert.')
    return
  end

  if vim.fn.input('Revert all ' .. #files .. ' changed files? (y/n): '):lower() ~= 'y' then
    return
  end
  snapshot.revert(M.__current_ref)

  vim.notify('Reverted ' .. #files .. ' files.')
end)

M.restore_snapshot = require_git_project(function(ref)
  M.__current_ref = ref or M.get_first_snapshot()

  if not M.__current_ref then
    vim.notify('No snapshot to restore.')
    return
  end

  M.with_restore_point(ref, function(restore_point)
    if not restore_point then
      vim.notify('No restore point selected.')
      return
    end

    snapshot.restore(restore_point.id)
    vim.cmd('checktime')
  end)
end)

M.restore_snapshot_file = require_git_project(function(restore_point_id)
  M.__current_ref = restore_point_id or M.get_first_snapshot()

  if not M.__current_ref then
    vim.notify('No snapshot to restore.')
    return
  end

  M.with_restore_point(restore_point_id, function(restore_point)
    if not restore_point then
      vim.notify('No restore point selected.')
      return
    end
    local files = get_changed_files(restore_point.id)

    vim.ui.select(
      vim.tbl_map(function(f)
        return vim.fn.fnamemodify(f.left, ':.')
      end, files),
      { prompt = 'Select a file to restore:' },
      function(choice, idx)
        if not choice then
          return
        end
        local file_data = files[idx]
        if snapshot.restore_file(restore_point.id, file_data.left) then
          vim.cmd('checktime')
        end
      end
    )
  end)
end)

--- Select a restore point and execute a function with it
--- @param restore_point_id string|nil
--- @param fn fun(restore_point: RestorePoint)
function M.with_restore_point(restore_point_id, fn)
  local restore_points = restore_point_id and snapshot.get_restore_points_by_parent(restore_point_id)
    or snapshot.get_restore_points()
  if #restore_points == 1 then
    return fn(restore_points[1])
  end
  vim.ui.select(restore_points, {
    prompt = 'Select a restore point to restore:',
    format_item = function(item)
      return (require('opencode.ui.icons').get('file') .. '[+%d,-%d] %s - %s (from: %s)'):format(
        item.files and #item.files or 0,
        item.deleted_files and #item.deleted_files or 0,
        item.id:sub(1, 8),
        utils.format_time(item.created_at) or 'unknown',
        item.from_snapshot_id and item.from_snapshot_id:sub(1, 8) or 'none'
      )
    end,
  }, function(selected_snapshot)
    if not selected_snapshot then
      return
    end
    fn(selected_snapshot)
    if snapshot then
      vim.notify('Reverted restore snapshot: ' .. selected_snapshot.id, vim.log.levels.INFO)
    else
      vim.notify('Failed to restore to snapshot: ' .. selected_snapshot.id, vim.log.levels.ERROR)
    end
  end)
end

M.close_diff = function()
  diff_tab.close_diff_tab()
end

M.reset_git_status = function()
  M.__is_git_project = nil
end

return M
