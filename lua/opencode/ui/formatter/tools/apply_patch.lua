local util = require('opencode.util')
local icons = require('opencode.ui.icons')

local M = {}

---@param file_path string
---@return string
local function resolve_file_name(file_path)
  if not file_path or file_path == '' then
    return ''
  end

  return file_path
end

---@param output Output
---@param part table
function M.format(output, part)
  if part.name ~= 'apply_patch' then
    return
  end
  local formatter_utils = require('opencode.ui.formatter.utils')
  local config = require('opencode.config')

  for _, file in ipairs(part.changes or {}) do
    formatter_utils.format_action(
      output,
      icons.get('edit'),
      'apply patch',
      file.path,
      formatter_utils.get_duration_text(part)
    )

    local patch = file.diff
    if (config.ui.output.tools.show_output or config.ui.output.tools.use_folds) and patch then
      local start_line = output:get_line_count() + 1
      local file_type = file and util.get_markdown_filetype(file.path) or ''
      formatter_utils.format_diff(output, patch, file_type, file.path)
      output:add_fold_with_threshold(start_line, config.ui.output.tools.show_output, config.ui.output.tools.use_folds)
    end
  end
end

---@param part table
---@return string, string, string
function M.summary(part)
  local file = part.changes and part.changes[1]
  local others_count = part.changes and #part.changes - 1 or 0
  local suffix = others_count > 0 and string.format(' (+%d more)', others_count) or ''
  return icons.get('edit'), 'apply patch', file and resolve_file_name(file.path) .. suffix or ''
end

return M
