local icons = require('opencode.ui.icons')
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

  local start_line = output:get_line_count() + 1
  if not (config.ui.output.tools.show_output or config.ui.output.tools.use_folds) then
    return
  end

  if metadata.output or metadata.command or input.command then
    local command = input.command or metadata.command or ''
    local command_output = metadata.output and metadata.output ~= '' and ('\n' .. metadata.output) or ''
    utils.format_code(output, vim.split('> ' .. command .. '\n' .. command_output, '\n'), 'bash')
  end

  output:add_fold_with_threshold(start_line, config.ui.output.tools.show_output, config.ui.output.tools.use_folds)
end

---@param _ OpencodeMessagePart
---@param input BashToolInput
---@return string, string, string
function M.summary(_, input)
  return icons.get('run'), 'run', input.description or ''
end

return M
