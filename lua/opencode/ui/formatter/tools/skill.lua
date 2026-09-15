local icons = require('opencode.ui.icons')
local utils = require('opencode.ui.formatter.utils')

local M = {}

---@param output Output
---@param part table
function M.format(output, part)
  local input = part.input or {}
  utils.format_action(output, icons.get('skill'), 'skill', input.name or '', utils.get_duration_text(part))
end

---@param _ table
---@param input table
---@return string, string, string
function M.summary(part)
  return icons.get('skill'), 'skill', (part.input and part.input.name) or ''
end

return M
