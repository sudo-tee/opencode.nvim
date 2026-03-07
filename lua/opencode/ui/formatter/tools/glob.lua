local M = {}

---@param output Output
---@param part OpencodeMessagePart
function M.format(output, part)
  local input = part.state and part.state.input or {}
  local metadata = part.state and part.state.metadata or {}

  local utils = require('opencode.ui.formatter.utils')
  local config = require('opencode.config')

  local icons = require('opencode.ui.icons')
  utils.format_action(output, icons.get('search'), 'glob', input.pattern, utils.get_duration_text(part))
  if not config.ui.output.tools.show_output then
    return
  end

  local prefix = metadata.truncated and ' more than' or ''
  output:add_line(string.format('Found%s `%d` file(s):', prefix, metadata.count or 0))
end

---@param _ OpencodeMessagePart
---@param input GlobToolInput
---@return string, string, string
function M.summary(_, input)
  return 'search', 'glob', input.pattern or ''
end

return M
