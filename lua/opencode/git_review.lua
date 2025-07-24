local Path = require('plenary.path')
local state = require('opencode.state')

local M = {}
local diff_tab = require('opencode.ui.diff_tab')

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

  list_changed_files = function(unstaged_only)
    if unstaged_only then
      local out = snapshot_git({ 'ls-files', '--modified' })
      return vim.split(out or '', '\n'), nil
    end

    if not M.__current_ref then
      return {}
    end
    local last_ref = M.__last_ref or 'HEAD'

    local current = snapshot_git({ 'rev-parse', last_ref }) or ''

    local result = snapshot_git({ 'diff', '--name-only', M.__current_ref, current })
    return vim.split(result or '', '\n'), M.__current_ref
  end,

  get_file_content_at_ref = function(file_path, ref)
    if not ref then
      return nil
    end
    local out, err = snapshot_git({ 'show', ref .. ':' .. file_path }, nil)
    if out then
      return write_to_temp_file(out)
    else
      return nil
    end
  end,

  is_tracked = function(file_path)
    local out = snapshot_git({ 'ls-files', '--error-unmatch', file_path })
    return out ~= nil
  end,

  get_first_commit = function()
    if not state.active_session then
      return nil
    end
    local out = snapshot_git({ 'rev-list', '--max-parents=0', 'HEAD' })
    return vim.trim(out or '')
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

local function get_changed_files()
  local files = {}
  local temp_files = {}

  local git_files = git.list_changed_files()

  for _, file in ipairs(git_files) do
    if file ~= '' then
      local abs_path = vim.fn.getcwd() .. '/' .. file
      local file_type = vim.fn.fnamemodify(file, ':e')

      local temp_file_path = nil
      if M.__last_ref ~= 'HEAD' then
        temp_file_path = git.get_file_content_at_ref(file, M.__current_ref)
      end

      local snapshot_path = git.get_file_content_at_ref(file, M.__last_ref)
      if snapshot_path then
        if temp_file_path then
          table.insert(temp_files, { temp_file_path, snapshot_path, path = abs_path, file_type = file_type })
        else
          table.insert(files, { abs_path, snapshot_path, path = abs_path, file_type = file_type })
        end
      else
        if temp_file_path then
          table.insert(temp_files, { temp_file_path, nil, path = abs_path, file_type = file_type })
        else
          table.insert(files, { abs_path, nil, path = abs_path, file_type = file_type })
        end
      end
    end
  end

  M.__changed_files = files

  return vim.list_extend(files, temp_files)
end

local function display_file_at_index(idx)
  local file_data = M.__changed_files[idx]
  local file_name = vim.fn.fnamemodify(file_data[1], ':t')
  local file_type = vim.fn.fnamemodify(file_data[1], ':e')
  vim.notify(string.format('Showing file %d of %d: %s', idx, #M.__changed_files, file_name))
  diff_tab.open_diff_tab(file_data[1], file_data[2], file_type)
end

---@param rev string
---@param n? number
---@return string|nil
local function get_git_rev(rev, n)
  if n == 0 or n == nil then
    return snapshot_git({ 'rev-parse', rev })
  elseif n < 0 then
    return snapshot_git({ 'rev-parse', string.format('%s~%d', rev, math.abs(n)) })
  end
  return nil
end

M.review = require_git_project(function(ref, last_ref)
  M.__current_ref = ref or git.get_first_commit()
  last_ref = get_git_rev(ref, last_ref) or 'HEAD'
  local files = get_changed_files()

  if #files == 0 then
    vim.notify('No changes to review.')
    return
  end

  if #files == 1 then
    M.__current_file_index = 1
    diff_tab.open_diff_tab(files[1][1], files[1][2], files[1].file_type)
  else
    vim.ui.select(
      vim.tbl_map(function(f)
        return vim.fn.fnamemodify(f.path, ':.')
      end, files),
      { prompt = 'Select a file to review:' },
      function(choice, idx)
        if not choice then
          return
        end
        M.__current_file_index = idx

        diff_tab.open_diff_tab(files[idx][1], files[idx][2], files[idx].file_type)
      end
    )
  end
end)

M.next_diff = require_git_project(function(ref, last_ref)
  M.__current_ref = ref or git.get_first_commit()
  M.__last_ref = last_ref and get_git_rev(ref, last_ref) or 'HEAD'
  if not M.__changed_files or not M.__current_file_index or M.__current_file_index >= #M.__changed_files then
    local files = get_changed_files()
    if #files == 0 then
      vim.notify('No changes to review.')
      return
    end
    M.__current_file_index = 1
  else
    M.__current_file_index = M.__current_file_index + 1
  end

  display_file_at_index(M.__current_file_index)
end)

M.prev_diff = require_git_project(function(ref, last_ref)
  M.__current_ref = ref or git.get_first_commit()
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

M.create_snapshot = require_git_project(function(title)
  title = title or ('Snapshot' .. os.date(' %Y-%m-%d %H:%M:%S'))

  local result = snapshot_git({ 'add', '.' })
  result = snapshot_git({ 'commit', '-m', title, '--author=opencode.nvim --no-gpg-sign <mail@opencode.nvim>' })

  if not result then
    vim.notify('Error creating snapshot: ' .. result, vim.log.levels.ERROR)
    return false
  end

  vim.notify('Created snapshot [' .. title .. '].')
  local snapshot_commit = snapshot_git({ 'rev-parse', 'HEAD' })
  return true, snapshot_commit
end)

M.revert_current = require_git_project(
  ---@param current_ref? string|nil
  ---@param last_ref? string|nil
  function(current_ref, last_ref)
    M.__current_ref = current_ref or M.get_first_commit()
    M.__last_ref = last_ref or 'HEAD'

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
  if not file_path then
    vim.notify('Invalid file path or snapshot path.')
    return false
  end
  local out, raw = snapshot_git({ 'checkout', ref or 'HEAD', '--', file_path })
  if not out then
    vim.notify('Error reverting file: ' .. (raw or ''), vim.log.levels.ERROR)
    return false
  end
  vim.notify('Reverted file: ' .. file_path .. ' at rev ' .. ref .. ' successfully.')
  return true
end)

M.revert_selected_file = require_git_project(function(ref, last_ref)
  M.__current_ref = ref or M.get_first_commit()
  M.__last_ref = last_ref and get_git_rev(ref, last_ref) or 'HEAD'

  local files = get_changed_files()

  if #files == 0 then
    vim.notify('No changes to revert.')
    return
  end

  if #files == 1 then
    if M.revert_file(files[1].path, ref) then
      vim.cmd('checktime')
    end
    return
  end

  vim.ui.select(
    vim.tbl_map(function(f)
      return vim.fn.fnamemodify(f.path, ':.')
    end, files),
    { prompt = 'Select a file to revert:' },
    function(choice, idx)
      if not choice then
        return
      end
      local file_data = files[idx]
      if M.revert_file(file_data.path, ref) then
        vim.cmd('checktime')
      end
    end
  )
end)

M.revert_all = require_git_project(function(ref, last_ref)
  M.__current_ref = ref or M.get_first_commit()
  M.__last_ref = last_ref and get_git_rev(ref, last_ref) or 'HEAD'

  local files = get_changed_files()

  if #files == 0 then
    vim.notify('No changes to revert.')
    return
  end

  if vim.fn.input('Revert all ' .. #files .. ' changed files? (y/n): '):lower() ~= 'y' then
    return
  end

  M.create_snapshot('Before Revert snapshot [' .. M.__current_ref .. ']')

  local success_count = 0
  for _, file_data in ipairs(files) do
    if M.revert_file(file_data[1], ref) then
      vim.cmd('checktime')
      success_count = success_count + 1
    end
  end

  vim.notify('Reverted ' .. success_count .. ' of ' .. #files .. ' files.')
end)

M.close_diff = function()
  diff_tab.close_diff_tab()
end

M.reset_git_status = function()
  M.__is_git_project = nil
end

return M
