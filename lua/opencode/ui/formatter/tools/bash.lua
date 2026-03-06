local M = {}

---@param ctx table
function M.format(ctx)
  ctx.format_action(ctx.output, 'run', 'run', ctx.input and ctx.input.description, ctx.duration_text)

  if not ctx.config.ui.output.tools.show_output then
    return
  end

  local input = ctx.input or {}
  local metadata = ctx.metadata or {}
  if metadata.output or metadata.command or input.command then
    local command = input.command or metadata.command or ''
    local command_output = metadata.output and metadata.output ~= '' and ('\n' .. metadata.output) or ''
    ctx.format_code(ctx.output, vim.split('> ' .. command .. '\n' .. command_output, '\n'), 'bash')
  end
end

---@param _ OpencodeMessagePart
---@param input BashToolInput
---@return string, string, string
function M.summary(_, input)
  return 'run', 'run', input.description or ''
end

return M
