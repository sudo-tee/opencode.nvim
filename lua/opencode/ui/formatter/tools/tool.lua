local utils = require('opencode.ui.formatter.utils')
local icons = require('opencode.ui.icons')
local M = {}

---@param output Output
---@param part table
function M.format(output, part)
  local icons = require('opencode.ui.icons')
  utils.format_action(output, icons.get('tool'), 'tool', part.name, utils.get_duration_text(part))
end

---@param _ table
---@param input table
---@return string, string, string
function M.summary(part)
  return icons.get('tool'), 'tool', part.description or ''
end

return M
