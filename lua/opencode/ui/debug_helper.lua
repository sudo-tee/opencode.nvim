local M = {}

local state = require('opencode.state')

function M.write_to_json_file(data)
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

function M.debug_output(windows)
  local session_formatter = require('opencode.ui.session_formatter')
  M.write_to_json_file(session_formatter:get_lines())
end

function M.debug_message(windows)
  local session_formatter = require('opencode.ui.session_formatter')
  local current_line = vim.api.nvim_win_get_cursor(windows.output_win)[1]
  local metadata = session_formatter.get_message_at_line(current_line) or {}
  M.write_to_json_file(metadata.message)
end

return M