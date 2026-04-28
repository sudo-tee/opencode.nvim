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

---@param input GrepToolInput|nil
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
---@param part OpencodeMessagePart
function M.format(output, part)
  if part.tool ~= 'grep' then
    return
  end

  local metadata = part.state and part.state.metadata or {}
  local input = part.state and part.state.input or nil

  local utils = require('opencode.ui.formatter.utils')
  local config = require('opencode.config')

  local icons = require('opencode.ui.icons')
  utils.format_action(output, icons.get('search'), 'grep', resolve_grep_string(input), utils.get_duration_text(part))

  local start_line = output:get_line_count() + 1
  if not (config.ui.output.tools.show_output or config.ui.output.tools.use_folds) then
    return
  end

  local prefix = metadata.truncated and ' more than' or ''
  output:add_line(
    string.format('Found%s `%d` match' .. (metadata.matches ~= 1 and 'es' or ''), prefix, metadata.matches or 0)
  )

  output:add_fold_with_threshold(start_line, config.ui.output.tools.show_output, config.ui.output.tools.use_folds)
end

---@param _ OpencodeMessagePart
---@param input GrepToolInput
---@return string, string, string
function M.summary(_, input)
  return icons.get('search'), 'grep', resolve_grep_string(input)
end

return M
