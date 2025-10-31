-- tests/helpers.lua
-- Helper functions for testing

local M = {}

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
  state.windows = ui.create_windows()

  -- we use the event manager to dispatch events
  require('opencode.event_manager').setup()

  -- we don't change any changes on session
  renderer._cleanup_subscriptions()

  -- but we do want event_manager subscriptions so set those back up
  renderer._setup_event_subscriptions()

  renderer.reset()

  M.mock_time_ago()

  if not config.config then
    config.config = vim.deepcopy(config.defaults)
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

function M.mock_time_ago()
  local util = require('opencode.util')
  local original_time_ago = util.time_ago

  ---@diagnostic disable-next-line: duplicate-set-field
  util.time_ago = function(timestamp)
    if timestamp > 1e12 then
      timestamp = math.floor(timestamp / 1000)
    end
    return os.date('!%Y-%m-%d %H:%M:%S', timestamp)
  end

  return function()
    util.time_ago = original_time_ago
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
          else
            table.insert(msg.parts, vim.deepcopy(part))
          end
          break
        end
      end
    end
  end

  return session_data
end

function M.get_session_from_events(events, with_session_updates)
  -- renderer needs a valid session id
  -- find the last session.updated event

  if with_session_updates then
    for i = #events, 1, -1 do
      local event = events[i]
      if event.type == 'session.updated' and event.properties.info and event.properties.info then
        return event.properties.info
      end
    end
  end
  for _, event in ipairs(events) do
    -- find the session id in a message or part event
    local properties = event.properties
    local session_id = properties.info and properties.info.sessionID or properties.part and properties.part.sessionID

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
