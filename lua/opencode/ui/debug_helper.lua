---@class OpencodeDebugHelper
---@field open_json_file fun(data: table)
---@field debug_output fun()
---@field debug_message fun()
---@field debug_session fun()
---@field save_captured_events fun(filename?: string): integer|nil
---@field open_log fun()
local M = {}

local event_capture = require('opencode.event_capture')

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
  local bufnr = state.windows and state.windows.output_buf
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    vim.notify('Output buffer not available', vim.log.levels.WARN)
    return
  end
  M.open_json_file({ lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false) })
end

function M.debug_message()
  local render_state = require('opencode.ui.renderer.ctx').current().render_state
  if not state.windows or not state.windows.output_win then
    vim.notify('Output window not available', vim.log.levels.WARN)
    return
  end
  local current_line = vim.api.nvim_win_get_cursor(state.windows.output_win --[[@as integer]])[1]

  -- Search backwards from current line to find nearest message
  for line = current_line, 1, -1 do
    local message_data = render_state:get_message_at_line(line)
    if message_data and message_data.message then
      M.open_json_file(message_data.message)
      return
    end
  end

  vim.notify('No message found in previous lines', vim.log.levels.WARN)
end

function M.debug_session()
  local observation = state.session.active_observation()
  if not observation then
    vim.notify('No active session observation', vim.log.levels.WARN)
    return
  end
  M.open_json_file(observation:read())
end

function M.save_captured_events(filename)
  return event_capture.save(filename)
end

function M.open_log()
  local log = require('opencode.log')
  local filename = log.get_path()
  if not filename then
    vim.notify('Plugin logging is disabled; enable logging.enabled to create a log file', vim.log.levels.WARN)
    return
  end
  if vim.fn.filereadable(filename) ~= 1 then
    vim.notify('Plugin log file does not exist yet: ' .. filename, vim.log.levels.WARN)
    return
  end

  vim.cmd('edit ' .. vim.fn.fnameescape(filename))
end

return M
