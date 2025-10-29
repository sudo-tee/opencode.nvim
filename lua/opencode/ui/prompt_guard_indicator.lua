local M = {}

local config = require('opencode.config')
local util = require('opencode.util')
local icons = require('opencode.ui.icons')
local context = require('opencode.context')

---Get the current prompt guard status
---@return boolean allowed
---@return string|nil error_message
function M.get_status()
  local mentioned_files = context.context.mentioned_files or {}
  return util.check_prompt_allowed(config.prompt_guard, mentioned_files)
end

---Check if guard will deny prompts
---@return boolean denied
function M.is_denied()
  local allowed, _ = M.get_status()
  return not allowed
end

---Get formatted indicator string with highlight (empty if allowed)
---@return string formatted_indicator
function M.get_formatted()
  if not M.is_denied() then
    -- Prompts are allowed - don't show anything
    return ''
  end

  -- Prompts will be denied - show red indicator
  local icon = icons.get('guard_on')
  return string.format('%%#OpencodeGuardDenied#%s%%*', icon)
end

return M
