local Path = require('plenary.path')
local state = require('opencode.state')

local M = {}

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
      local snapshot_dir = state.active_session.snapshot_path
      local result = vim.fn.system('git -C "' .. snapshot_dir .. '" ls-files --modified')
      return vim.split(result, '\n'), nil
    end

    if not M.__current_ref then
      return {}
    end
    local last_ref = M.__last_ref or 'HEAD'

    local snapshot_dir = state.active_session.snapshot_path
    local current = vim.fn.system('git -C "' .. snapshot_dir .. '" rev-parse ' .. last_ref):gsub('\n', '')
    local result =
      vim.fn.system('git -C "' .. snapshot_dir .. '" diff --name-only ' .. M.__current_ref .. ' ' .. current)
    return vim.split(result, '\n'), M.__current_ref
  end,

  get_file_content_at_ref = function(file_path, ref)
    if not ref then
      return nil
    end

    local snapshot_dir = state.active_session.snapshot_path
    local temp_file = vim.fn.tempname()
    vim.fn.system('git -C "' .. snapshot_dir .. '" show ' .. ref .. ':' .. file_path .. ' > ' .. temp_file)
    return temp_file
  end,

  is_tracked = function(file_path)
    local snapshot_dir = state.active_session.snapshot_path
    local success =
      os.execute('git -C "' .. snapshot_dir .. '" ls-files --error-unmatch "' .. file_path .. '" > /dev/null 2>&1')
    return success == 0
  end,

  get_first_commit = function()
    if not state.active_session then
      return nil
    end

    local snapshot_dir = state.active_session.snapshot_path
    local result = vim.fn.system('git -C "' .. snapshot_dir .. '" rev-list --max-parents=0 HEAD')
    return vim.trim(result)
  end,
}

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
  local git_files, ref = git.list_changed_files()

  for _, file in ipairs(git_files) do
    if file ~= '' then
      local file_path = vim.fn.getcwd() .. '/' .. file
      local snapshot_path = git.get_file_content_at_ref(file, ref)
      if snapshot_path then
        table.insert(files, { file_path, snapshot_path })
      else
        table.insert(files, { file_path, nil })
      end
    end
  end

  M.__changed_files = files
  return files
end

local function close_diff_tab()
  if M.__diff_tab and vim.api.nvim_tabpage_is_valid(M.__diff_tab) then
    pcall(vim.api.nvim_del_augroup_by_name, 'OpencodeDiffCleanup' .. M.__diff_tab)

    local windows = vim.api.nvim_tabpage_list_wins(M.__diff_tab)

    local buffers = {}
    for _, win in ipairs(windows) do
      local buf = vim.api.nvim_win_get_buf(win)
      table.insert(buffers, buf)
    end

    vim.api.nvim_set_current_tabpage(M.__diff_tab)
    pcall(vim.cmd, 'tabclose')

    for _, buf in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(buf) then
        local visible = false
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          if vim.api.nvim_win_get_buf(win) == buf then
            visible = true
            break
          end
        end

        if not visible then
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
      end
    end
  end
  M.__diff_tab = nil
end

local function show_file_diff(file_path, snapshot_path)
  close_diff_tab()

  vim.cmd('tabnew')
  M.__diff_tab = vim.api.nvim_get_current_tabpage()

  if snapshot_path then
    vim.cmd('edit ' .. vim.fn.fnameescape(snapshot_path))
    vim.cmd('setlocal readonly buftype=nofile nomodifiable')
    vim.cmd('setlocal filetype=' .. vim.fn.fnamemodify(file_path, ':e'))
    vim.cmd('diffthis')

    vim.cmd('vsplit ' .. vim.fn.fnameescape(file_path))
    vim.cmd('diffthis')
  else
    vim.cmd('edit ' .. vim.fn.fnameescape(file_path))
  end

  -- Set up auto-cleanup
  local augroup = vim.api.nvim_create_augroup('OpencodeGitDiffCleanup' .. M.__diff_tab, { clear = true })
  local tab_windows = vim.api.nvim_tabpage_list_wins(M.__diff_tab)
  vim.api.nvim_create_autocmd('WinClosed', {
    group = augroup,
    pattern = tostring(tab_windows[1]) .. ',' .. tostring(tab_windows[2]),
    callback = close_diff_tab,
  })
end

local function display_file_at_index(idx)
  local file_data = M.__changed_files[idx]
  local file_name = vim.fn.fnamemodify(file_data[1], ':t')
  vim.notify(string.format('Showing file %d of %d: %s', idx, #M.__changed_files, file_name))
  show_file_diff(file_data[1], file_data[2])
end

M.review = require_git_project(function(ref, last_ref)
  M.__current_ref = ref or git.get_first_commit()
  M.__last_ref = last_ref or 'HEAD'
  local files = get_changed_files()

  if #files == 0 then
    vim.notify('No changes to review.')
    return
  end

  if #files == 1 then
    M.__current_file_index = 1
    show_file_diff(files[1][1], files[1][2])
  else
    vim.ui.select(
      vim.tbl_map(function(f)
        return vim.fn.fnamemodify(f[1], ':.')
      end, files),
      { prompt = 'Select a file to review:' },
      function(choice, idx)
        if not choice then
          return
        end
        M.__current_file_index = idx
        show_file_diff(files[idx][1], files[idx][2])
      end
    )
  end
end)

M.next_diff = require_git_project(function(ref, last_ref)
  M.__current_ref = ref or git.get_first_commit()
  M.__last_ref = last_ref or 'HEAD'
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
  M.__last_ref = last_ref or 'HEAD'
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

M.revert_current = require_git_project(function(ref, last_ref)
  M.__current_ref = ref or M.get_first_commit()
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

  if M.revert_file(changed_file[1], ref) then
    vim.cmd('e!')
  end
end)

M.revert_file = require_git_project(function(file_path, ref)
  if not file_path then
    vim.notify('Invalid file path or snapshot path.')
    return false
  end

  local snapshot_dir = state.active_session.snapshot_path
  local revert_cmd = 'git -C "' .. snapshot_dir .. '" checkout ' .. (ref or 'HEAD') .. ' -- "' .. file_path .. '"'
  local result = vim.fn.system(revert_cmd)

  if vim.v.shell_error ~= 0 then
    vim.notify('Error reverting file: ' .. result, vim.log.levels.ERROR)
    return false
  end

  vim.notify('Reverted file: ' .. file_path .. ' at rev ' .. ref .. ' successfully.')
  return true
end)

M.revert_all = require_git_project(function(ref, last_ref)
  M.__current_ref = ref or M.get_first_commit()
  M.__last_ref = last_ref or 'HEAD'

  local files = get_changed_files()

  if #files == 0 then
    vim.notify('No changes to revert.')
    return
  end

  if vim.fn.input('Revert all ' .. #files .. ' changed files? (y/n): '):lower() ~= 'y' then
    return
  end

  local success_count = 0
  for _, file_data in ipairs(files) do
    if M.revert_file(file_data[1], ref) then
      success_count = success_count + 1
    end
  end

  vim.notify('Reverted ' .. success_count .. ' of ' .. #files .. ' files.')
end)

M.close_diff = function()
  if M.__diff_tab and vim.api.nvim_tabpage_is_valid(M.__diff_tab) then
    pcall(vim.api.nvim_del_augroup_by_name, 'OpencodeGitDiffCleanup' .. M.__diff_tab)
    vim.api.nvim_set_current_tabpage(M.__diff_tab)
    pcall(vim.cmd, 'tabclose')
    M.__diff_tab = nil
  end
end

M.reset_git_status = function()
  M.__is_git_project = nil
end

return M
