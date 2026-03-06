local M = {}

---@param ctx table
function M.format(ctx)
  ctx.format_action(ctx.output, 'web', 'fetch', ctx.input and ctx.input.url, ctx.duration_text)
end

---@param _ OpencodeMessagePart
---@param input WebFetchToolInput
---@return string, string, string
function M.summary(_, input)
  return 'web', 'fetch', input.url or ''
end

return M
