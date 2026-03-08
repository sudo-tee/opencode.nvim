local M = {}

---@param output Output
---@param part OpencodeMessagePart
function M.format(output, part)
  if part.tool ~= 'list' then
    return
  end
  local input = part.state and part.state.input or {}
  local metadata = part.state and part.state.metadata or {}
  local tool_output = part.state and part.state.output or ''

  local utils = require('opencode.ui.formatter.utils')
  local config = require('opencode.config')

  local icons = require('opencode.ui.icons')
  utils.format_action(output, icons.get('list'), 'list', input.path or '', utils.get_duration_text(part))
  if not config.ui.output.tools.show_output then
    return
  end

  local lines = vim.split(vim.trim(tool_output), '\n')
  if #lines < 1 or metadata.count == 0 then
    output:add_line('No files found.')
    return
  end
  if #lines > 1 then
    output:add_line('Files:')
    for i = 2, #lines do
      local file = vim.trim(lines[i])
      if file ~= '' then
        output:add_line('  • ' .. file)
      end
    end
  end
  if metadata.truncated then
    output:add_line(string.format('Results truncated, showing first %d files', metadata.count or '?'))
  end
end

---@param _ OpencodeMessagePart
---@param input ListToolInput
---@return string, string, string
function M.summary(_, input)
  return icons.get('list'), 'list', input.path or ''
end

return M
