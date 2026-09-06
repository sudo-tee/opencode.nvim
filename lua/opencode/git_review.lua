local state = require('opencode.state')
local snapshot = require('opencode.snapshot')
local diff_tab = require('opencode.ui.diff_tab')
local utils = require('opencode.util')
local session = require('opencode.session')
local picker = require('opencode.ui.picker')
local Promise = require('opencode.promise')

local M = {}
local breakpoint
local review_cache
local generation = 0

local function is_current(context)
  return context.generation == generation and state.active_session == context.session and vim.fn.getcwd() == context.cwd
end

local function run_snapshot(context, name, ...)
  local args, count = { ... }, select('#', ...)
  return snapshot
    .with_context(function()
      return snapshot[name](unpack(args, 1, count)):await()
    end, context)
    :await()
end

local function review_action(fn)
  return function(...)
    generation = generation + 1
    local context = {
      cwd = vim.fn.getcwd(),
      session = state.active_session,
      current_file = vim.fn.expand('%:p'),
      generation = generation,
      first_snapshot = M.get_first_snapshot(),
    }
    local args, count = { ... }, select('#', ...)
    return Promise.spawn(function()
      if not context.session then
        error('No active session found.')
      end
      return fn(context, unpack(args, 1, count))
    end)
  end
end

---@return string|nil
function M.get_first_snapshot()
  if breakpoint and breakpoint.session == state.active_session and breakpoint.cwd == vim.fn.getcwd() then
    return breakpoint.id
  end
  for _, msg in ipairs(state.messages or {}) do
    local ids = session.get_message_snapshot_ids(msg)
    if ids and #ids > 0 then
      return ids[1]
    end
  end
end

local function get_changed_files(context, ref)
  ref = ref or context.first_snapshot
  if not ref then
    return {}
  end
  local patch = run_snapshot(context, 'patch', ref)
  local files = {}
  for _, file in ipairs(patch and patch.files or {}) do
    if not is_current(context) then
      return {}
    end
    files[#files + 1] = run_snapshot(context, 'diff_file', ref, file)
  end
  return files
end

local function select_item(context, items, opts)
  if not is_current(context) or #items == 0 then
    return nil
  end
  if #items == 1 then
    return items[1]
  end
  local selected = Promise.new()
  picker.select(items, opts, function(choice)
    selected:resolve(choice)
  end)
  local choice = selected:await()
  return is_current(context) and choice or nil
end

local function select_file(context, files, prompt)
  return select_item(context, files, {
    prompt = prompt,
    format_item = function(file)
      return file.left
    end,
  })
end

local function display(context, file)
  if file and is_current(context) then
    diff_tab.open_diff_tab(file.left, file.right, file.file_type)
  end
end

---@type fun(ref?: string): Promise<nil>
M.review = review_action(function(context, ref)
  local files = get_changed_files(context, ref)
  if #files == 0 and is_current(context) then
    vim.notify('No changes to review.')
    return
  end
  display(context, select_file(context, files, 'Select a file to review:'))
end)

local function navigate(context, ref, direction)
  ref = ref or context.first_snapshot
  if
    not review_cache
    or review_cache.cwd ~= context.cwd
    or review_cache.session ~= context.session
    or review_cache.ref ~= ref
  then
    local files = get_changed_files(context, ref)
    if not is_current(context) then
      return
    end
    review_cache = { cwd = context.cwd, session = context.session, ref = ref, files = files }
  end
  local files = review_cache.files
  if #files == 0 then
    vim.notify('No changes to review.')
    return
  end
  local index = review_cache.index or (direction == 1 and 0 or 1)
  index = (index - 1 + direction) % #files + 1
  review_cache.index = index
  display(context, files[index])
end

---@type fun(ref?: string): Promise<nil>
M.next_diff = review_action(function(context, ref)
  return navigate(context, ref, 1)
end)
---@type fun(ref?: string): Promise<nil>
M.prev_diff = review_action(function(context, ref)
  return navigate(context, ref, -1)
end)

local function revert_file(context, file, ref)
  if not is_current(context) then
    return
  end
  local result = run_snapshot(context, 'revert_file', ref or context.first_snapshot, file)
  review_cache = nil
  if result and is_current(context) then
    vim.cmd('checktime')
  end
  return result
end

---@type fun(file: string, ref?: string): Promise<table|nil>
M.revert_file = review_action(revert_file)
---@type fun(ref?: string): Promise<table|nil>
M.revert_current = review_action(function(context, ref)
  local files = get_changed_files(context, ref)
  for _, file in ipairs(files) do
    if file.left == context.current_file and is_current(context) then
      if vim.fn.input('Revert current file? (y/n): '):lower() == 'y' then
        return revert_file(context, file.left, ref)
      end
      return
    end
  end
  if is_current(context) then
    vim.notify('No changes to revert.')
  end
end)

---@type fun(ref?: string): Promise<table|nil>
M.revert_selected_file = review_action(function(context, ref)
  local files = get_changed_files(context, ref)
  local file = select_file(context, files, 'Select a file to revert:')
  if file then
    return revert_file(context, file.left, ref)
  end
end)

---@type fun(ref?: string): Promise<table|nil>
M.revert_all = review_action(function(context, ref)
  local files = get_changed_files(context, ref)
  if not is_current(context) then
    return
  end
  if #files == 0 then
    vim.notify('No changes to revert.')
    return
  end
  if vim.fn.input('Revert all ' .. #files .. ' changed files? (y/n): '):lower() ~= 'y' then
    return
  end
  local result = run_snapshot(context, 'revert', ref or context.first_snapshot)
  review_cache = nil
  if result and is_current(context) then
    vim.notify('Reverted ' .. #files .. ' files.')
  end
  return result
end)

local function select_restore_point(context, parent)
  local points
  if parent then
    points = snapshot.get_restore_points_by_parent(parent)
  else
    points = snapshot.get_restore_points()
  end
  return select_item(context, points or {}, {
    prompt = 'Select a restore point to restore:',
    format_item = function(item)
      return ('%s - %s'):format(item.id:sub(1, 8), utils.format_time(item.created_at) or 'unknown')
    end,
  })
end

---@type fun(parent?: string): Promise<boolean|nil>
M.restore_snapshot = review_action(function(context, parent)
  local point = select_restore_point(context, parent)
  if not point then
    return
  end
  local result = run_snapshot(context, 'restore', point.id)
  review_cache = nil
  if result and is_current(context) then
    vim.cmd('checktime')
  end
  return result
end)
M.restore_snapshot_all = M.restore_snapshot

---@type fun(parent?: string): Promise<boolean|nil>
M.restore_snapshot_file = review_action(function(context, parent)
  local point = select_restore_point(context, parent)
  if not point then
    return
  end
  local file = select_file(context, get_changed_files(context, point.id), 'Select a file to restore:')
  if not file then
    return
  end
  local result = run_snapshot(context, 'restore_file', point.id, file.left)
  review_cache = nil
  if result and is_current(context) then
    vim.cmd('checktime')
  end
  return result
end)

---@type fun(parent: string|nil, fn: fun(point: RestorePoint): any): Promise<any>
M.with_restore_point = review_action(function(context, parent, fn)
  local point = select_restore_point(context, parent)
  if point then
    return fn(point)
  end
end)

---@type fun(): Promise<string|nil>
M.create_snapshot = review_action(function(context)
  local id = run_snapshot(context, 'create')
  if is_current(context) then
    breakpoint = { id = id, session = context.session, cwd = context.cwd }
    review_cache = nil
  end
  return id
end)

function M.close_diff()
  generation = generation + 1
  diff_tab.close_diff_tab()
end

function M.reset_git_status()
  generation = generation + 1
  review_cache = nil
end

return M
