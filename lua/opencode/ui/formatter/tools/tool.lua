local M = {}

---@param ctx table
function M.format(ctx)
  ctx.format_action(ctx.output, 'tool', 'tool', ctx.tool_type, ctx.duration_text)
end

---@param _ OpencodeMessagePart
---@param input table
---@return string, string, string
function M.summary(_, input)
  return 'tool', 'tool', input.description or ''
end

return M
