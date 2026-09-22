local icons = require('opencode.ui.icons')
local utils = require('opencode.ui.formatter.utils')
local config = require('opencode.config')

local M = {}

---@param output Output
---@param part table
function M.format(output, part)
  if part.name ~= 'execute' then
    return
  end

  local input = part.input or {}
  utils.format_action(output, icons.get('run'), 'execute', '', utils.get_duration_text(part))

  local start_line = output:get_line_count() + 1
  if input.code and (config.ui.output.tools.show_output or config.ui.output.tools.use_folds) then
    utils.format_code(output, vim.split(input.code, '\n'), 'javascript')
    output:add_fold_with_threshold(start_line, config.ui.output.tools.show_output, config.ui.output.tools.use_folds)
  end
end

---@param part table
---@return string, string, string
function M.summary(part)
  return icons.get('run'), 'execute', ''
end

return M
