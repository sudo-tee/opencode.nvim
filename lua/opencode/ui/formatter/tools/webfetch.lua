local M = {}
local utils = require('opencode.ui.formatter.utils')

---@param output Output
---@param part OpencodeMessagePart
function M.format(output, part)
  local icons = require('opencode.ui.icons')
  utils.format_action(output, icons.get('web'), 'fetch', part.state and part.state.input and part.state.input.url, utils.get_duration_text(part))
end

---@param _ OpencodeMessagePart
---@param input WebFetchToolInput
---@return string, string, string
function M.summary(_, input)
  return 'web', 'fetch', input.url or ''
end

return M
