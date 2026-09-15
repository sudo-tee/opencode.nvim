local icons = require('opencode.ui.icons')
local M = {}

---@param output Output
---@param part table
function M.format(output, part)
  if part.name ~= 'glob' then
    return
  end

  local input = part.input or {}

  local utils = require('opencode.ui.formatter.utils')
  local config = require('opencode.config')

  local icons = require('opencode.ui.icons')
  utils.format_action(output, icons.get('search'), 'glob', input.pattern, utils.get_duration_text(part))

  local start_line = output:get_line_count() + 1
  if not (config.ui.output.tools.show_output or config.ui.output.tools.use_folds) then
    return
  end

  local search = part.search or {}
  local prefix = search.truncated and ' more than' or ''
  output:add_line(
    search.count and string.format('Found%s `%d` file(s):', prefix, search.count) or 'File count unavailable'
  )

  output:add_fold_with_threshold(start_line, config.ui.output.tools.show_output, config.ui.output.tools.use_folds)
end

---@param part table
---@return string, string, string
function M.summary(part)
  return icons.get('search'), 'glob', (part.input and part.input.pattern) or ''
end

return M
