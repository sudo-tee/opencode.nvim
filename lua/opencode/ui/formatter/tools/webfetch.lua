local M = {}
local icons = require('opencode.ui.icons')
local utils = require('opencode.ui.formatter.utils')

---@param output Output
---@param part table
function M.format(output, part)
  if part.name ~= 'webfetch' then
    return
  end

  utils.format_action(output, icons.get('web'), 'fetch', part.input and part.input.url, utils.get_duration_text(part))
end

---@param part table
---@return string, string, string
function M.summary(part)
  return icons.get('web'), 'fetch', (part.input and part.input.url) or ''
end

return M
