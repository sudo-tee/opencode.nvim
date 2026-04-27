local util = require('opencode.util')
local icons = require('opencode.ui.icons')

local M = {}

---@param file_path string
---@return string
local function resolve_file_name(file_path)
  if not file_path or file_path == '' then
    return ''
  end

  local cwd = vim.fn.getcwd()
  local absolute = vim.fn.fnamemodify(file_path, ':p')
  if vim.startswith(absolute, cwd .. '/') then
    return absolute:sub(#cwd + 2)
  end
  return absolute
end

---@param output Output
---@param part OpencodeMessagePart
function M.format(output, part)
  if part.tool ~= 'apply_patch' then
    return
  end
  local formatter_utils = require('opencode.ui.formatter.utils')
  local config = require('opencode.config')

  local metadata = part.state and part.state.metadata or {}
  for _, file in ipairs(metadata.files or {}) do
    formatter_utils.format_action(
      output,
      icons.get('edit'),
      'apply patch',
      file.relativePath or file.filePath,
      formatter_utils.get_duration_text(part)
    )

    local patch = file.diff or file.patch
    if (config.ui.output.tools.show_output or config.ui.output.tools.use_folds) and patch then
      local start_line = output:get_line_count() + 1
      local file_type = file and util.get_markdown_filetype(file.filePath) or ''
      formatter_utils.format_diff(output, patch, file_type)
      output:add_fold_with_threshold(start_line, config.ui.output.tools.show_output, config.ui.output.tools.use_folds)
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
  return icons.get('edit'), 'apply patch', file and resolve_file_name(file.filePath) .. suffix or ''
end

return M
