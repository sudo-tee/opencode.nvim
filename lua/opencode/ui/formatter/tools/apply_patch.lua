local util = require('opencode.util')
local helpers = require('opencode.ui.formatter.tools.helpers')

local M = {}

---@param ctx table
function M.format(ctx)
  local metadata = ctx.metadata or {}
  for _, file in ipairs(metadata.files or {}) do
    ctx.format_action(ctx.output, 'edit', 'apply patch', file.relativePath or file.filePath, ctx.duration_text)
    if ctx.config.ui.output.tools.show_output and file.diff then
      local file_type = file and util.get_markdown_filetype(file.filePath) or ''
      ctx.format_diff(ctx.output, file.diff, file_type)
    end
  end
end

---@param _ OpencodeMessagePart
---@param _ table
---@param metadata ApplyPatchToolMetadata
---@return string, string, string
function M.summary(_, _, metadata)
  local file = metadata.files and metadata.files[1]
  local others_count = metadata.files and #metadata.files - 1 or 0
  local suffix = others_count > 0 and string.format(' (+%d more)', others_count) or ''
  return 'edit', 'apply patch', file and helpers.resolve_file_name(file.filePath) .. suffix or ''
end

return M
