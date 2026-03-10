local M = {}
local icons = require('opencode.ui.icons')
local utils = require('opencode.ui.formatter.utils')

---@param output Output
---@param part OpencodeMessagePart
function M.format(output, part)
  if part.tool ~= 'webfetch' then
    return
  end

  utils.format_action(
    output,
    icons.get('web'),
    'fetch',
    part.state and part.state.input and part.state.input.url,
    utils.get_duration_text(part)
  )
end

---@param _ OpencodeMessagePart
---@param input WebFetchToolInput
---@return string, string, string
function M.summary(_, input)
  return icons.get('web'), 'fetch', input.url or ''
end

return M
