local helpers = require('opencode.ui.formatter.tools.helpers')

local M = {}

---@param ctx table
function M.format(ctx)
  local metadata = ctx.metadata or {}
  local grep_str = helpers.resolve_grep_string(ctx.input)

  ctx.format_action(ctx.output, 'search', 'grep', grep_str, ctx.duration_text)
  if not ctx.config.ui.output.tools.show_output then
    return
  end

  local prefix = metadata.truncated and ' more than' or ''
  ctx.output:add_line(
    string.format('Found%s `%d` match' .. (metadata.matches ~= 1 and 'es' or ''), prefix, metadata.matches or 0)
  )
end

---@param _ OpencodeMessagePart
---@param input GrepToolInput
---@return string, string, string
function M.summary(_, input)
  return 'search', 'grep', helpers.resolve_grep_string(input)
end

return M
