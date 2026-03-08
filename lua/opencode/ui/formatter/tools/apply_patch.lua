local util = require('opencode.util')

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

  local metadata = part.state and part.state.metadata or {}
  for _, file in ipairs(metadata.files or {}) do
    local utils = require('opencode.ui.formatter.utils')
    local config = require('opencode.config')

    local icons = require('opencode.ui.icons')
    utils.format_action(
      output,
      icons.get('edit'),
      'apply patch',
      file.relativePath or file.filePath,
      utils.get_duration_text(part)
    )
    if config.ui.output.tools.show_output and file.diff then
      local file_type = file and util.get_markdown_filetype(file.filePath) or ''
      utils.format_diff(output, file.diff, file_type)
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
