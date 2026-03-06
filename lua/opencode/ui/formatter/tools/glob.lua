local M = {}

---@param ctx table
function M.format(ctx)
  local input = ctx.input or {}
  local metadata = ctx.metadata or {}

  ctx.format_action(ctx.output, 'search', 'glob', input.pattern, ctx.duration_text)
  if not ctx.config.ui.output.tools.show_output then
    return
  end

  local prefix = metadata.truncated and ' more than' or ''
  ctx.output:add_line(string.format('Found%s `%d` file(s):', prefix, metadata.count or 0))
end

---@param _ OpencodeMessagePart
---@param input GlobToolInput
---@return string, string, string
function M.summary(_, input)
  return 'search', 'glob', input.pattern or ''
end

return M
