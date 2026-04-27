local icons = require('opencode.ui.icons')
local M = {}

---@param output Output
---@param part OpencodeMessagePart
function M.format(output, part)
  if part.tool ~= 'glob' then
    return
  end

  local input = part.state and part.state.input or {}
  local metadata = part.state and part.state.metadata or {}

  local utils = require('opencode.ui.formatter.utils')
  local config = require('opencode.config')

  local icons = require('opencode.ui.icons')
  utils.format_action(output, icons.get('search'), 'glob', input.pattern, utils.get_duration_text(part))

  local start_line = output:get_line_count() + 1
  if not (config.ui.output.tools.show_output or config.ui.output.tools.use_folds) then
    return
  end

  local prefix = metadata.truncated and ' more than' or ''
  output:add_line(string.format('Found%s `%d` file(s):', prefix, metadata.count or 0))

  output:add_fold_with_threshold(start_line, config.ui.output.tools.show_output, config.ui.output.tools.use_folds)
end

---@param _ OpencodeMessagePart
---@param input GlobToolInput
---@return string, string, string
function M.summary(_, input)
  return icons.get('search'), 'glob', input.pattern or ''
end

return M
