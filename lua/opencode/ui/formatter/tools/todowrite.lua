local icons = require('opencode.ui.icons')
local M = {}

---@param output Output
---@param part OpencodeMessagePart
function M.format(output, part)
  if part.tool ~= 'todowrite' then
    return
  end
  local utils = require('opencode.ui.formatter.utils')
  local config = require('opencode.config')

  local icons = require('opencode.ui.icons')
  utils.format_action(
    output,
    icons.get('plan'),
    'plan',
    (part.state and part.state.title or ''),
    utils.get_duration_text(part)
  )

  local start_line = output:get_line_count() + 1
  if not (config.ui.output.tools.show_output or config.ui.output.tools.use_folds) then
    return
  end

  local statuses = { in_progress = '-', completed = 'x', pending = ' ' }
  local todos = part.state and part.state.input and part.state.input.todos or {}
  for _, item in ipairs(todos) do
    output:add_line(string.format('- [%s] %s ', statuses[item.status], item.content))
  end

  output:add_fold_with_threshold(start_line, config.ui.output.tools.show_output, config.ui.output.tools.use_folds)
end

---@param part OpencodeMessagePart
---@return string, string, string
function M.summary(part)
  return icons.get('plan'), 'plan', part.state and part.state.title or ''
end

return M
