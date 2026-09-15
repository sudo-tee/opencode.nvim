local icons = require('opencode.ui.icons')
local M = {}

---@param output Output
---@param part table
function M.format(output, part)
  if part.name ~= 'todowrite' then
    return
  end
  local utils = require('opencode.ui.formatter.utils')
  local config = require('opencode.config')

  local icons = require('opencode.ui.icons')
  utils.format_action(
    output,
    icons.get('plan'),
    'plan',
    part.title or '',
    utils.get_duration_text(part)
  )

  local start_line = output:get_line_count() + 1
  if not (config.ui.output.tools.show_output or config.ui.output.tools.use_folds) then
    return
  end

  local statuses = { in_progress = '-', completed = 'x', pending = ' ' }
  local todos = part.todos or {}

  for _, item in ipairs(todos) do
    output:add_line(string.format('- [%s] %s ', statuses[item.state], item.text))
  end

  output:add_fold_with_threshold(start_line, config.ui.output.tools.show_output, config.ui.output.tools.use_folds)
end

---@param part table
---@return string, string, string
function M.summary(part)
  return icons.get('plan'), 'plan', part.title or ''
end

return M
