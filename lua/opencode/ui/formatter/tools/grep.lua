local icons = require('opencode.ui.icons')
local M = {}

---@param value any
---@return string
local function normalize_part(value)
  if value == nil or value == vim.NIL then
    return ''
  end

  local value_type = type(value)
  if value_type == 'string' then
    return value
  end
  if value_type == 'number' or value_type == 'boolean' then
    return tostring(value)
  end

  return ''
end

---@param input table|nil
---@return string
local function resolve_grep_string(input)
  if not input then
    return ''
  end
  local path_part = normalize_part(input.path)
  if path_part == '' then
    path_part = normalize_part(input.include)
  end
  local pattern_part = normalize_part(input.pattern)
  return table.concat(
    vim.tbl_filter(function(p)
      return p ~= nil and p ~= ''
    end, { path_part, pattern_part }),
    ' '
  )
end

---@param output Output
---@param part table
function M.format(output, part)
  if part.name ~= 'grep' then
    return
  end

  local input = part.input

  local utils = require('opencode.ui.formatter.utils')
  local config = require('opencode.config')

  local icons = require('opencode.ui.icons')
  utils.format_action(output, icons.get('search'), 'grep', resolve_grep_string(input), utils.get_duration_text(part))

  local start_line = output:get_line_count() + 1
  if not (config.ui.output.tools.show_output or config.ui.output.tools.use_folds) then
    return
  end

  local search = part.search or {}
  local prefix = search.truncated and ' more than' or ''
  local count = search.count
  output:add_line(
    count and string.format('Found%s `%d` match%s', prefix, count, count ~= 1 and 'es' or '')
      or 'Match count unavailable'
  )

  output:add_fold_with_threshold(start_line, config.ui.output.tools.show_output, config.ui.output.tools.use_folds)
end

---@param part table
---@return string, string, string
function M.summary(part)
  return icons.get('search'), 'grep', resolve_grep_string(part.input)
end

return M
