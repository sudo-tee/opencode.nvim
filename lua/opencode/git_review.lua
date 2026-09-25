local state = require('opencode.state')
local snapshot = require('opencode.snapshot')
local diff_tab = require('opencode.ui.diff_tab')
local session_diff = require('opencode.ui.session_diff')
local utils = require('opencode.util')
local picker = require('opencode.ui.picker')
local Promise = require('opencode.promise')

local M = {}
local breakpoint
local review_cache
local generation = 0

local function entry_snapshot_ids(entry)
  local result = {}
  local seen = {}
  for _, content in ipairs(entry and entry.content or {}) do
    if content.kind == 'patch' and content.hash and not seen[content.hash] then
      seen[content.hash] = true
      result[#result + 1] = content.hash
    end
  end
  return result
end

local function observed_entries()
  local observation = state.session.active_observation()
  local observed = observation and observation:read() or nil
  local entries = {}
  for _, id in ipairs(observed and observed.entry_order or {}) do
    local entry = observed.entries_by_id[id]
    if not entry then
      error('Observation entry order contains an unknown id: ' .. id)
    end
    entries[#entries + 1] = entry
  end
  return entries
end

local function is_current(context)
  return context.generation == generation and state.active_session == context.session and vim.fn.getcwd() == context.cwd
end

local function v2_connection()
  local connection = state.opencode_server
  return connection and connection.protocol == 'v2' and connection or nil
end

local function review_turn(context, message_id, to, file_path)
  if file_path and session_diff.toggle_file(file_path, message_id, context.session.id) then
    return
  end
  local connection = assert(v2_connection())
  ---@cast connection OpencodeV2Connection
  local files = connection.operations.diff_session(connection, context.session.id, message_id, to, utils.apply_reverse_path_map):await()
  if not is_current(context) then
    return
  end
  session_diff.open(files, context.session, {
    from = message_id,
    to = to,
    file = file_path,
    load_turns = function()
      return M.list_review_turns()
    end,
    review_range = function(from, last)
      return M.review(from, last)
    end,
  })
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
  for _, entry in ipairs(observed_entries()) do
    local ids = entry_snapshot_ids(entry)
    if #ids > 0 then
      return ids[1]
    end
  end
end

---@return string|nil
function M.get_latest_snapshot()
  local entries = observed_entries()
  for index = #entries, 1, -1 do
    local ids = entry_snapshot_ids(entries[index])
    if #ids > 0 then
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

---@type fun(ref?: string, to?: string): Promise<nil>
M.review = review_action(function(context, ref, to)
  if v2_connection() then
    return review_turn(context, ref, to)
  end
  local files = get_changed_files(context, ref)
  if #files == 0 and is_current(context) then
    vim.notify('No changes to review.')
    return
  end
  display(context, select_file(context, files, 'Select a file to review:'))
end)

---@type fun(message_id: string, path: string, session_id: string): Promise<nil>
M.toggle_file = review_action(function(context, message_id, path, session_id)
  if context.session.id ~= session_id or not v2_connection() then
    return
  end
  ---@type string?
  local from
  for _, entry in ipairs(observed_entries()) do
    if entry.kind == 'user' then
      from = entry.id
    end
    if entry.id == message_id then
      if not from then
        error('Tool has no preceding user message')
      end
      return review_turn(context, from, nil, path)
    end
  end
  error('Tool message is no longer in the active session')
end)

---@type fun(): Promise<table[]>
M.list_review_turns = review_action(function(context)
  local connection = assert(v2_connection())
  ---@cast connection OpencodeV2Connection
  local turns = {}
  local cursor
  local seen = {}
  repeat
    local page = connection.operations.list_messages(connection, context.session.id, cursor, 100):await()
    if not is_current(context) then
      return {}
    end
    for _, message in ipairs(page.data) do
      if message.type == 'user' then
        turns[#turns + 1] = { id = message.id, text = message.text, created = message.time.created }
      end
    end
    cursor = page.cursor.next
    if cursor then
      if seen[cursor] then
        error('V2 list_messages returned a repeated cursor', 0)
      end
      seen[cursor] = true
    end
  until cursor == nil
  -- V2 pages arrive newest first; range endpoints are ordered oldest to newest.
  return vim.fn.reverse(turns)
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
  if v2_connection() then
    if not session_diff.select(1) then
      return review_turn(context, ref)
    end
    return
  end
  return navigate(context, ref, 1)
end)
---@type fun(ref?: string): Promise<nil>
M.prev_diff = review_action(function(context, ref)
  if v2_connection() then
    if not session_diff.select(-1) then
      return review_turn(context, ref)
    end
    return
  end
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
  session_diff.close()
  diff_tab.close_diff_tab()
end

function M.reset_git_status()
  generation = generation + 1
  review_cache = nil
end

return M
