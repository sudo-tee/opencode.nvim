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
    local first_line = vim.split(input.code, '\n', { plain = true })[1] or ''
    if #first_line > 80 then
      first_line = first_line:sub(1, 77) .. '...'
    end
    if first_line ~= '' then
      start_line = output:add_line('**Input** — `' .. first_line .. '`')
    end
    utils.format_code(output, vim.split(input.code, '\n'), 'javascript')
    output:add_fold_with_threshold(start_line, false, config.ui.output.tools.use_folds)
  end
  utils.format_tool_result(output, part, { collapsed = true })
end

---@param part table
---@return string, string, string
function M.summary(part)
  return icons.get('run'), 'execute', ''
end

return M
