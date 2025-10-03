---@class OpencodeDebugHelper
---@field open_json_file fun(data: table)
---@field debug_output fun()
---@field debug_message fun()
---@field debug_session fun()
local M = {}

local state = require('opencode.state')

function M.open_json_file(data)
  local tmpfile = vim.fn.tempname() .. '.json'
  local json_str = vim.json.encode(data)
  vim.api.nvim_set_current_win(state.last_code_win_before_opencode)
  vim.fn.writefile(vim.split(json_str, '\n'), tmpfile)
  vim.cmd('e ' .. tmpfile)
  if vim.fn.executable('jq') == 1 then
    vim.cmd('silent! %!jq .')
    vim.cmd('silent! w')
  end
end

function M.debug_output()
  local session_formatter = require('opencode.ui.session_formatter')
  M.open_json_file(session_formatter:get_lines())
end

function M.debug_message()
  local session_formatter = require('opencode.ui.session_formatter')
  local current_line = vim.api.nvim_win_get_cursor(state.windows.output_win)[1]
  local metadata = session_formatter.get_message_at_line(current_line) or {}
  M.open_json_file(metadata.message)
end

function M.debug_session()
  local session = require('opencode.session')
  local session_path = session.get_workspace_session_path()
  if not state.active_session then
    print('No active session')
    return
  end
  vim.api.nvim_set_current_win(state.last_code_win_before_opencode)
  vim.cmd('e ' .. session_path .. '/' .. state.active_session.id .. '.json')
end

return M
