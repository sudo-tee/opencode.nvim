-- tests/helpers.lua
-- Helper functions for testing

local M = {}

-- Create a temporary file with content
function M.create_temp_file(content)
  local tmp_file = vim.fn.tempname()
  local file = io.open(tmp_file, 'w')
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
    pcall(vim.cmd, 'bdelete! ' .. bufnr)
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
      pcall(vim.cmd, 'bdelete! ' .. bufnr)
    end
  end
  -- Reset any other editor state as needed
  pcall(vim.cmd, 'silent! %bwipeout!')
end

-- Mock input function
function M.mock_input(return_value)
  local original_input = vim.fn.input
  vim.fn.input = function(...)
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

function M.get_session_from_events(events)
  -- renderer needs a valid session id
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
  local renderer = require('opencode.ui.renderer')
  if event.type == 'message.updated' then
    renderer.on_message_updated(event)
  elseif event.type == 'message.part.updated' then
    renderer.on_part_updated(event)
  elseif event.type == 'message.removed' then
    renderer.on_message_removed(event)
  elseif event.type == 'message.part.removed' then
    renderer.on_part_removed(event)
  elseif event.type == 'session.compacted' then
    renderer.on_session_compacted(event)
  elseif event.type == 'permission.updated' then
    renderer.on_permission_updated(event)
  elseif event.type == 'permission.replied' then
    renderer.on_permission_replied(event)
  end
end

function M.replay_events(events)
  for _, event in ipairs(events) do
    M.replay_event(event)
  end
end

function M.normalize_namespace_ids(extmarks)
  local normalized = vim.deepcopy(extmarks)
  for _, mark in ipairs(normalized) do
    if mark[4] and mark[4].ns_id then
      mark[4].ns_id = 3
    end
  end
  return normalized
end

function M.capture_output(output_buf, namespace)
  return {
    lines = vim.api.nvim_buf_get_lines(output_buf, 0, -1, false) or {},
    extmarks = vim.api.nvim_buf_get_extmarks(output_buf, namespace, 0, -1, { details = true }) or {},
  }
end

return M
