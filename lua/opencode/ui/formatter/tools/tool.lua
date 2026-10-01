local utils = require('opencode.ui.formatter.utils')
local icons = require('opencode.ui.icons')
local M = {}

---@param output Output
---@param part table
function M.format(output, part)
  utils.format_action(output, icons.get('tool'), 'tool', part.name, utils.get_duration_text(part))
  utils.format_tool_input(output, part.input)
  utils.format_tool_result(output, part)
end

---@param part table
---@return string, string, string
function M.summary(part)
  return icons.get('tool'), 'tool', part.description or ''
end

return M
