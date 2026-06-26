-- tests/helpers.lua
-- Helper functions for testing

local M = {}

M.MOCK_CWD = '/mock/project/path'

function M.replay_setup()
  local config = require('opencode.config')
  local config_file = require('opencode.config_file')
  local state = require('opencode.state')
  local ui = require('opencode.ui.ui')
  local renderer = require('opencode.ui.renderer')
  local permission_window = require('opencode.ui.permission_window')
  local question_window = require('opencode.ui.question_window')
  local reference_picker = require('opencode.ui.reference_picker')

  local empty_promise = require('opencode.promise').new():resolve(nil)
  config_file.config_promise = empty_promise
  config_file.project_promise = empty_promise
  config_file.providers_promise = empty_promise

  if state.windows then
    ui.close_windows(state.windows)
  end

  renderer.reset()
  -- Ensure replay tests render all messages (lazy-render is always active)
  require('opencode.ui.renderer.ctx').lazy_render_count = math.huge
  permission_window.clear_all()
  question_window._clear_dialog()
  question_window._current_question = nil
  question_window._current_question_index = 1
  question_window._collected_answers = {}
  question_window._answering = false
  reference_picker.clear_all()

  ---@diagnostic disable-next-line: duplicate-set-field
  require('opencode.session').project_id = function()
    return nil
  end

  state.model.set_mode('build') -- default mode for tests

  -- we use the event manager to dispatch events, have to setup before ui.create_windows
  require('opencode.event_manager').setup()

  state.ui.set_windows(ui.create_windows())

  -- disable fetching session and rendering it (we'll handle it at a lower level)
  renderer.render_full_session = function()
    return require('opencode.promise').new():resolve(nil)
  end

  M.mock_time_utils()
  M.mock_getcwd()

  if not config.config then
    config.config = vim.deepcopy(config.defaults)
  end
end

function M.mock_getcwd()
  local original_getcwd = vim.fn.getcwd

  ---@diagnostic disable-next-line: duplicate-set-field
  vim.fn.getcwd = function()
    return M.MOCK_CWD
  end

  return function()
    vim.fn.getcwd = original_getcwd
  end
end

-- Create a temporary file with content
function M.create_temp_file(content)
  local tmp_file = vim.fn.tempname()
  local file = io.open(tmp_file, 'w')

  if not file then
    return nil
  end

  file:write(content or 'Test file content')
  file:close()
  return tmp_file
end

-- Clean up temporary file
function M.delete_temp_file(file)
  vim.fn.delete(file)
end

-- Open a buffer for a file
function M.open_buffer(file)
  vim.cmd('edit ' .. file)
  return vim.api.nvim_get_current_buf()
end

-- Close a buffer
function M.close_buffer(bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_command, 'bdelete! ' .. bufnr)
  end
end

-- Set visual selection programmatically
function M.set_visual_selection(start_line, start_col, end_line, end_col)
  -- Enter visual mode
  vim.cmd('normal! ' .. start_line .. 'G' .. start_col .. 'lv' .. end_line .. 'G' .. end_col .. 'l')
end

-- Reset editor state
function M.reset_editor()
  -- Clear all buffers
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    -- Skip non-existing or invalid buffers
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_command, 'bdelete! ' .. bufnr)
    end
  end
  -- Reset any other editor state as needed
  pcall(vim.api.nvim_command, 'silent! %bwipeout!')
end

-- Mock input function
function M.mock_input(return_value)
  local original_input = vim.fn.input
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.fn.input = function(_)
    return return_value
  end
  return function()
    vim.fn.input = original_input
  end
end

-- Mock notification function
function M.mock_notify()
  local notifications = {}
  local original_notify = vim.notify

  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(msg, level, opts)
    table.insert(notifications, {
      msg = msg,
      level = level,
      opts = opts,
    })
  end

  return {
    reset = function()
      vim.notify = original_notify
    end,
    get_notifications = function()
      return notifications
    end,
    clear = function()
      notifications = {}
    end,
  }
end

function M.mock_time_utils()
  local util = require('opencode.util')
  local original_format_time = util.format_time

  ---@diagnostic disable-next-line: duplicate-set-field
  util.format_time = function(timestamp)
    if timestamp > 1e12 then
      timestamp = math.floor(timestamp / 1000)
    end
    return os.date('!%Y-%m-%d %H:%M:%S', timestamp)
  end

  return function()
    util.format_time = original_format_time
  end
end

function M.load_test_data(filename)
  local f = io.open(filename, 'r')
  if not f then
    error('Could not open ' .. filename)
  end
  local content = f:read('*all')
  f:close()
  return vim.json.decode(content)
end

function M.load_session_from_events(events)
  local session_data = {}
  local parts_by_id = {}

  for _, event in ipairs(events) do
    local properties = event.properties

    if event.type == 'message.updated' and properties.info then
      local msg = properties.info
      local existing_msg = nil
      for _, m in ipairs(session_data) do
        if m.info.id == msg.id then
          existing_msg = m
          break
        end
      end

      if existing_msg then
        existing_msg.info = vim.deepcopy(msg)
      else
        table.insert(session_data, {
          info = vim.deepcopy(msg),
          parts = {},
        })
      end
    elseif event.type == 'message.part.updated' and properties.part then
      local part = properties.part
      for _, msg in ipairs(session_data) do
        if msg.info.id == part.messageID then
          local existing_part = nil
          for i, p in ipairs(msg.parts) do
            if p.id == part.id then
              existing_part = i
              break
            end
          end

          if existing_part then
            -- Preserve state.input when the later event omits it
            local new_input = part.state and part.state.input
            local old_input = msg.parts[existing_part].state and msg.parts[existing_part].state.input
            if
              type(new_input) == 'table'
              and next(new_input) == nil
              and type(old_input) == 'table'
              and next(old_input) ~= nil
            then
              part.state.input = old_input
            end
            msg.parts[existing_part] = vim.deepcopy(part)
            parts_by_id[part.id] = msg.parts[existing_part]
          else
            table.insert(msg.parts, vim.deepcopy(part))
            parts_by_id[part.id] = msg.parts[#msg.parts]
          end
          break
        end
      end
    elseif event.type == 'message.part.delta' and properties.partID and properties.messageID and properties.field then
      local part = parts_by_id[properties.partID]

      if not part then
        for _, msg in ipairs(session_data) do
          if msg.info.id == properties.messageID then
            part = {
              id = properties.partID,
              messageID = properties.messageID,
              sessionID = properties.sessionID,
              type = properties.field == 'text' and 'text' or nil,
            }
            if properties.field == 'text' then
              part.text = ''
            end
            table.insert(msg.parts, part)
            parts_by_id[properties.partID] = part
            break
          end
        end
      end

      if part then
        local field = properties.field
        local delta = properties.delta
        if type(delta) == 'string' then
          local current = part[field]
          if type(current) == 'string' then
            part[field] = current .. delta
          else
            part[field] = delta
          end
        else
          part[field] = delta
        end
      end
    end
  end

  return session_data
end

function M.get_session_from_events(events, with_session_updates)
  -- renderer needs a valid session id
  -- merge session.updated events and use the latest updated session

  if with_session_updates then
    local sessions_by_id = {}
    local last_session_id = nil

    for _, event in ipairs(events) do
      if event.type == 'session.updated' and event.properties.info then
        local info = event.properties.info
        if info.id then
          sessions_by_id[info.id] = vim.deepcopy(info)
          last_session_id = info.id
        end
      end
    end

    if last_session_id then
      return sessions_by_id[last_session_id]
    end
  end
  for _, event in ipairs(events) do
    -- find the session id in a message or part event
    local properties = event.properties
    local session_id = properties.info and properties.info.sessionID
      or properties.part and properties.part.sessionID
      or properties.sessionID

    if session_id then
      ---@diagnostic disable-next-line: missing-fields
      return { id = session_id }
    end
  end

  return nil
end

function M.replay_event(event)
  event = vim.deepcopy(event)
  -- synthetic "emit" by adding the event to the throttling emitter's queue
  require('opencode.state').event_manager.throttling_emitter:enqueue(event)
end

function M.replay_events(events)
  for _, event in ipairs(events) do
    M.replay_event(event)
  end
end

function M.normalize_namespace_ids(extmarks)
  local normalized = vim.deepcopy(extmarks)
  for i, mark in ipairs(normalized) do
    mark[1] = i
    if mark[4] and mark[4].ns_id then
      mark[4].ns_id = 3
    end
  end
  return normalized
end

local function is_array(value)
  local max = 0
  local count = 0

  for key, _ in pairs(value) do
    if type(key) ~= 'number' or key < 1 or key % 1 ~= 0 then
      return false
    end

    max = math.max(max, key)
    count = count + 1
  end

  return count == max
end

local function encode_pretty_json(value, level)
  level = level or 0

  if type(value) ~= 'table' then
    return vim.json.encode(value)
  end

  local indent = string.rep('  ', level)
  local child_indent = string.rep('  ', level + 1)

  if is_array(value) then
    if #value == 0 then
      return '[]'
    end

    local items = {}
    for index = 1, #value do
      items[#items + 1] = child_indent .. encode_pretty_json(value[index], level + 1)
    end

    return '[\n' .. table.concat(items, ',\n') .. '\n' .. indent .. ']'
  end

  local keys = vim.tbl_keys(value)
  table.sort(keys)

  if #keys == 0 then
    return '{}'
  end

  local items = {}
  for _, key in ipairs(keys) do
    items[#items + 1] = child_indent .. vim.json.encode(key) .. ': ' .. encode_pretty_json(value[key], level + 1)
  end

  return '{\n' .. table.concat(items, ',\n') .. '\n' .. indent .. '}'
end

function M.encode_pretty_json(value)
  return encode_pretty_json(value) .. '\n'
end

local existing_snapshot

local function snapshot_without_window(snapshot)
  local copy = vim.deepcopy(snapshot)
  copy.window = nil
  return copy
end

local function window_entry_json(window)
  return '  "window": ' .. encode_pretty_json(window, 1)
end

local function append_window_to_existing_snapshot(content, window)
  local content_without_newline = content:sub(-1) == '\n' and content:sub(1, -2) or content
  local before_closing_brace = content_without_newline:match('^(.*)%}%s*$')

  if not before_closing_brace then
    return nil
  end

  local json = before_closing_brace:gsub('%s+$', '') .. ',\n' .. window_entry_json(window) .. '\n}'
  if content:sub(-1) == '\n' then
    json = json .. '\n'
  end

  return json
end

function M.encode_snapshot_json(snapshot, existing_file)
  local existing = existing_snapshot(existing_file)
  if existing and vim.deep_equal(snapshot_without_window(existing), snapshot_without_window(snapshot)) then
    local file = io.open(existing_file, 'r')
    if file then
      local content = file:read('*all')
      file:close()

      if vim.deep_equal(existing.window, snapshot.window) then
        return content
      end

      if not existing.window then
        local json = append_window_to_existing_snapshot(content, snapshot.window)
        if json then
          return json
        end
      end
    end
  end

  return M.encode_pretty_json(snapshot)
end

existing_snapshot = function(filename)
  if not filename or vim.fn.filereadable(filename) ~= 1 then
    return nil
  end

  local file = io.open(filename, 'r')
  if not file then
    return nil
  end

  local content = file:read('*all')
  file:close()

  local ok, snapshot = pcall(vim.json.decode, content)
  if ok and type(snapshot) == 'table' then
    return snapshot
  end

  return nil
end

local function action_key(action)
  return encode_pretty_json(action)
end

local function same_action_multiset(left, right)
  if type(left) ~= 'table' or type(right) ~= 'table' or #left ~= #right then
    return false
  end

  local counts = {}
  for _, action in ipairs(left) do
    local key = action_key(action)
    counts[key] = (counts[key] or 0) + 1
  end

  for _, action in ipairs(right) do
    local key = action_key(action)
    if not counts[key] then
      return false
    end

    counts[key] = counts[key] - 1
    if counts[key] == 0 then
      counts[key] = nil
    end
  end

  return next(counts) == nil
end

local function preserve_existing_action_order(actions, existing_file)
  local snapshot = existing_snapshot(existing_file)
  if snapshot and same_action_multiset(snapshot.actions, actions) then
    return snapshot.actions
  end

  return actions
end

local function output_window_for_buffer(output_buf)
  local state = require('opencode.state')
  local output_win = state.windows and state.windows.output_win

  if output_win and vim.api.nvim_win_is_valid(output_win) and vim.api.nvim_win_get_buf(output_win) == output_buf then
    return output_win
  end

  error('Could not resolve output window for buffer')
end

local function capture_window(output_buf)
  local output_win = output_window_for_buffer(output_buf)
  local output_window = require('opencode.ui.output_window')
  local line_count = vim.api.nvim_buf_line_count(output_buf)

  return {
    cursor = vim.api.nvim_win_get_cursor(output_win),
    visible_bottom = vim.api.nvim_win_call(output_win, function()
      return vim.fn.line('w$')
    end),
    line_count = line_count,
    effective_bottom = output_window.get_effective_bottom_line(output_buf, line_count),
  }
end

function M.existing_snapshot_timestamp(filename)
  if not filename or vim.fn.filereadable(filename) ~= 1 then
    return nil, false
  end

  local file = io.open(filename, 'r')
  if not file then
    return nil, false
  end

  local content = file:read('*all')
  file:close()

  local ok, snapshot = pcall(vim.json.decode, content)
  if ok and type(snapshot) == 'table' then
    return snapshot.timestamp, true
  end

  return nil, true
end

function M.output_snapshot(output_buf, namespace, existing_file)
  local actual = M.capture_output(output_buf, namespace)
  local timestamp, has_existing_snapshot = M.existing_snapshot_timestamp(existing_file)
  local actions = preserve_existing_action_order(actual.actions, existing_file)

  local snapshot = {
    lines = actual.lines,
    extmarks = M.normalize_namespace_ids(actual.extmarks),
    actions = actions,
    window = actual.window,
  }

  if timestamp ~= nil then
    snapshot.timestamp = timestamp
  elseif not has_existing_snapshot then
    snapshot.timestamp = os.time()
  end

  return snapshot
end

function M.capture_output(output_buf, namespace)
  local extmarks = vim.api.nvim_buf_get_extmarks(output_buf, namespace, 0, -1, { details = true }) or {}
  table.sort(extmarks, function(a, b)
    if a[2] ~= b[2] then
      return a[2] < b[2]
    end

    if a[3] ~= b[3] then
      return a[3] < b[3]
    end

    local a_priority = a[4] and a[4].priority or 0
    local b_priority = b[4] and b[4].priority or 0
    if a_priority ~= b_priority then
      return a_priority > b_priority
    end

    return a[1] < b[1]
  end)

  return {
    lines = vim.api.nvim_buf_get_lines(output_buf, 0, -1, false) or {},
    extmarks = extmarks,
    actions = vim.deepcopy(require('opencode.ui.renderer.ctx').render_state:get_all_actions()),
    window = capture_window(output_buf),
  }
end

return M
