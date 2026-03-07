local M = {}

---@param input GrepToolInput|nil
---@return string
local function resolve_grep_string(input)
  if not input then
    return ''
  end
  local path_part = input.path or input.include or ''
  local pattern_part = input.pattern or ''
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
  local metadata = part.state and part.state.metadata or {}
  local input = part.state and part.state.input or nil

  local utils = require('opencode.ui.formatter.utils')
  local config = require('opencode.config')

  local icons = require('opencode.ui.icons')
  utils.format_action(output, icons.get('search'), 'grep', resolve_grep_string(input), utils.get_duration_text(part))
  if not config.ui.output.tools.show_output then
    return
  end

  local prefix = metadata.truncated and ' more than' or ''
  output:add_line(
    string.format('Found%s `%d` match' .. (metadata.matches ~= 1 and 'es' or ''), prefix, metadata.matches or 0)
  )
end

---@param _ OpencodeMessagePart
---@param input GrepToolInput
---@return string, string, string
function M.summary(_, input)
  return 'search', 'grep', resolve_grep_string(input)
end

return M
