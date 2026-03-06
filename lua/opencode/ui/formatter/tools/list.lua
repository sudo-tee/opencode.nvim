local M = {}

---@param ctx table
function M.format(ctx)
  local input = ctx.input or {}
  local metadata = ctx.metadata or {}
  local tool_output = ctx.tool_output

  ctx.format_action(ctx.output, 'list', 'list', input.path or '', ctx.duration_text)
  if not ctx.config.ui.output.tools.show_output then
    return
  end

  local lines = vim.split(vim.trim(tool_output or ''), '\n')
  if #lines < 1 or metadata.count == 0 then
    ctx.output:add_line('No files found.')
    return
  end
  if #lines > 1 then
    ctx.output:add_line('Files:')
    for i = 2, #lines do
      local file = vim.trim(lines[i])
      if file ~= '' then
        ctx.output:add_line('  • ' .. file)
      end
    end
  end
  if metadata.truncated then
    ctx.output:add_line(string.format('Results truncated, showing first %d files', metadata.count or '?'))
  end
end

---@param _ OpencodeMessagePart
---@param input ListToolInput
---@return string, string, string
function M.summary(_, input)
  return 'list', 'list', input.path or ''
end

return M
