---@class OpencodeDebugHelper
---@field open_json_file fun(data: table)
---@field debug_output fun()
---@field debug_message fun()
---@field debug_session fun()
---@field save_captured_events fun(filename: string)
local M = {}

local state = require('opencode.state')

function M.open_json_file(data)
  local tmpfile = vim.fn.tempname() .. '.json'
  local json_str = vim.json.encode(data)
  if state.last_code_win_before_opencode then
    vim.api.nvim_set_current_win(state.last_code_win_before_opencode --[[@as integer]])
  end
  vim.fn.writefile(vim.split(json_str, '\n'), tmpfile)
  vim.cmd('e ' .. tmpfile)
  if vim.fn.executable('jq') == 1 then
    vim.cmd('silent! %!jq .')
    vim.cmd('silent! w')
  end
end

function M.debug_output()
  local session_formatter = require('opencode.ui.formatter')
  M.open_json_file(session_formatter:get_lines())
end

function M.debug_message()
  local renderer = require('opencode.ui.renderer')
  if not state.windows or not state.windows.output_win then
    vim.notify('Output window not available', vim.log.levels.WARN)
    return
  end
  local current_line = vim.api.nvim_win_get_cursor(state.windows.output_win --[[@as integer]])[1]

  -- Search backwards from current line to find nearest message
  for line = current_line, 1, -1 do
    local message_data = renderer._render_state:get_message_at_line(line)
    if message_data and message_data.message then
      M.open_json_file(message_data.message)
      return
    end
  end

  vim.notify('No message found in previous lines', vim.log.levels.WARN)
end

function M.debug_session()
  local session = require('opencode.session')
  local session_path = session.get_workspace_session_path()
  if not state.active_session then
    print('No active session')
    return
  end
  if state.last_code_win_before_opencode then
    vim.api.nvim_set_current_win(state.last_code_win_before_opencode --[[@as integer]])
  end
  vim.cmd('e ' .. session_path .. '/' .. state.active_session.id .. '.json')
end

function M.save_captured_events(filename)
  if not state.event_manager then
    vim.notify('Event manager not initialized', vim.log.levels.ERROR)
    return
  end

  local events = state.event_manager.captured_events
  if not events or #events == 0 then
    vim.notify('No captured events to save', vim.log.levels.WARN)
    return
  end

  local json_str = vim.json.encode(events)
  local lines = vim.split(json_str, '\n')
  vim.fn.writefile(lines, filename)
  vim.notify(string.format('Saved %d events to %s', #events, filename), vim.log.levels.INFO)
end

return M
