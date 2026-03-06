local M = {}

---@param ctx table
function M.format(ctx)
  ctx.format_action(ctx.output, 'plan', 'plan', (ctx.title or ''), ctx.duration_text)
  if not ctx.config.ui.output.tools.show_output then
    return
  end

  local todos = ctx.input and ctx.input.todos or {}
  for _, item in ipairs(todos) do
    local statuses = { in_progress = '-', completed = 'x', pending = ' ' }
    ctx.output:add_line(string.format('- [%s] %s ', statuses[item.status], item.content))
  end
end

---@param part OpencodeMessagePart
---@return string, string, string
function M.summary(part)
  return 'plan', 'plan', part.state and part.state.title or ''
end

return M
