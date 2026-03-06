local util = require('opencode.util')
local helpers = require('opencode.ui.formatter.tools.helpers')

local M = {}

---@param ctx table
function M.format(ctx)
  local input = ctx.input or {}
  local metadata = ctx.metadata or {}
  local tool_output = ctx.tool_output
  local tool_type = ctx.tool_type

  local file_name = tool_type == 'read' and helpers.resolve_display_file_name(input.filePath or '', tool_output)
    or helpers.resolve_file_name(input.filePath or '')

  local file_type = input.filePath and util.get_markdown_filetype(input.filePath) or ''

  ctx.format_action(ctx.output, tool_type, tool_type, file_name, ctx.duration_text)

  if not ctx.config.ui.output.tools.show_output then
    return
  end

  if tool_type == 'edit' and metadata.diff then
    ctx.format_diff(ctx.output, metadata.diff, file_type)
  elseif tool_type == 'write' and input.content then
    ctx.format_code(ctx.output, vim.split(input.content, '\n'), file_type)
  end
end

---@param part OpencodeMessagePart
---@param input FileToolInput
---@return string, string, string
function M.summary(part, input)
  local tool = part.tool
  if tool == 'read' then
    local tool_output = part.state and part.state.output or nil
    return 'read', 'read', helpers.resolve_display_file_name(input.filePath, tool_output)
  end
  return tool, tool, helpers.resolve_file_name(input.filePath)
end

return M
