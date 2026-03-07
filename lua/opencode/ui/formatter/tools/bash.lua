local M = {}

---@param output Output
---@param part OpencodeMessagePart
function M.format(output, part)
  if part.tool ~= 'bash' then
    return
  end

  local utils = require('opencode.ui.formatter.utils')
  local config = require('opencode.config')

  ---@type BashToolInput
  local input = part.state and part.state.input or {}

  ---@type BashToolMetadata
  local metadata = part.state and part.state.metadata or {}

  local icons = require('opencode.ui.icons')
  utils.format_action(output, icons.get('run'), 'run', input.description, utils.get_duration_text(part))

  if not config.ui.output.tools.show_output then
    return
  end

  if metadata.output or metadata.command or input.command then
    local command = input.command or metadata.command or ''
    local command_output = metadata.output and metadata.output ~= '' and ('\n' .. metadata.output) or ''
    utils.format_code(output, vim.split('> ' .. command .. '\n' .. command_output, '\n'), 'bash')
  end
end

---@param _ OpencodeMessagePart
---@param input BashToolInput
---@return string, string, string
function M.summary(_, input)
  return 'run', 'run', input.description or ''
end

return M
