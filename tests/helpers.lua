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

  local empty_promise = require('opencode.promise').new():resolve(nil)
  config_file.config_promise = empty_promise
  config_file.project_promise = empty_promise
  config_file.providers_promise = empty_promise

  ---@diagnostic disable-next-line: duplicate-set-field
  require('opencode.session').project_id = function()
    return nil
  end

  state.current_mode = 'build' -- default mode for tests

  -- we use the event manager to dispatch events, have to setup before ui.create_windows
  require('opencode.event_manager').setup()

  state.windows = ui.create_windows()

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
            msg.parts[existing_part] = vim.deepcopy(part)
            parts_by_id[part.id] = msg.parts[existing_part]
          else
            table.insert(msg.parts, vim.deepcopy(part))
            parts_by_id[part.id] = msg.parts[#msg.parts]
          end
          break
        end
      end
    elseif event.type == 'message.part.delta'
      and properties.partID
      and properties.messageID
      and properties.field then
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

function M.capture_output(output_buf, namespace)
  local renderer = require('opencode.ui.renderer')
  return {
    lines = vim.api.nvim_buf_get_lines(output_buf, 0, -1, false) or {},
    extmarks = vim.api.nvim_buf_get_extmarks(output_buf, namespace, 0, -1, { details = true }) or {},
    actions = vim.deepcopy(renderer._render_state:get_all_actions()),
  }
end

return M
