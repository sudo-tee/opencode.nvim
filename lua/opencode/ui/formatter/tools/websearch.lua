local icons = require('opencode.ui.icons')
local utils = require('opencode.ui.formatter.utils')
local config = require('opencode.config')

local M = {}

---@param output Output
---@param part table
function M.format(output, part)
  if part.name ~= 'websearch' then
    return
  end

  local input = part.input or {}
  utils.format_action(output, icons.get('web'), 'search', input.query or '', utils.get_duration_text(part))

  local start_line = output:get_line_count() + 1
  if not (config.ui.output.tools.show_output or config.ui.output.tools.use_folds) then
    return
  end

  local result = utils.tool_result_text(part)
  if result ~= '' then
    output:add_empty_line()
    output:add_lines(vim.split(result, '\n'))
    output:add_empty_line()
  end

  output:add_fold_with_threshold(start_line, config.ui.output.tools.show_output, config.ui.output.tools.use_folds)
end

---@param part table
---@return string, string, string
function M.summary(part)
  return icons.get('web'), 'search', (part.input and part.input.query) or ''
end

return M
