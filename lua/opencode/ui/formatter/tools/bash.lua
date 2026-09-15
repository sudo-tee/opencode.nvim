local icons = require('opencode.ui.icons')
local M = {}

---@param value any
---@return string
local function one_line(value)
  if type(value) ~= 'string' then
    return ''
  end
  return vim.trim(value:gsub('[\r\n]+', ' '))
end

---@param output Output
---@param part table
function M.format(output, part)
  if part.name ~= 'bash' then
    return
  end

  local utils = require('opencode.ui.formatter.utils')
  local config = require('opencode.config')

  local icons = require('opencode.ui.icons')
  utils.format_action(
    output,
    icons.get('run'),
    'run',
    part.description or part.command or '',
    utils.get_duration_text(part)
  )

  local start_line = output:get_line_count() + 1
  if not (config.ui.output.tools.show_output or config.ui.output.tools.use_folds) then
    return
  end

  local output_text = utils.tool_result_text(part)
  if part.command or output_text ~= '' then
    local command = part.command or ''
    local command_output = output_text ~= '' and ('\n' .. output_text) or ''
    utils.format_code(output, vim.split('> ' .. command .. '\n' .. command_output, '\n'), 'bash')
  end

  output:add_fold_with_threshold(start_line, config.ui.output.tools.show_output, config.ui.output.tools.use_folds)
end

---@param part table
---@return string, string, string
function M.summary(part)
  return icons.get('run'), 'run', one_line(part.command or part.description or '')
end

return M
