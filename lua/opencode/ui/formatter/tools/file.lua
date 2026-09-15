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

---@param file_path string
---@param tool_output? string
---@return boolean
local function is_directory_path(file_path, tool_output)
  if not file_path or file_path == '' then
    return false
  end

  if vim.endswith(file_path, '/') then
    return true
  end

  return type(tool_output) == 'string' and tool_output:match('<type>directory</type>') ~= nil
end

---@param file_path string
---@param tool_output? string
---@return string
local function resolve_display_file_name(file_path, tool_output)
  local resolved = resolve_file_name(file_path)

  if resolved ~= '' and is_directory_path(file_path, tool_output) and not vim.endswith(resolved, '/') then
    resolved = resolved .. '/'
  end

  return resolved
end

---@param output Output
---@param part table
function M.format(output, part)
  local tool_output = require('opencode.ui.formatter.utils').tool_result_text(part)
  local tool_type = part.name
  local target = part.target or {}

  local file_name = tool_type == 'read' and resolve_display_file_name(target.path or '', tool_output)
    or resolve_file_name(target.path or '')

  local file_type = target.path and util.get_markdown_filetype(target.path) or ''

  local utils = require('opencode.ui.formatter.utils')
  local config = require('opencode.config')

  local icon_text = icons.get(tool_type)
  utils.format_action(output, icon_text, tool_type, file_name, utils.get_duration_text(part))

  if file_name ~= '' and target.path then
    local action_line = output:get_line_count()
    local line_content = output:get_line(action_line)
    output:add_target({
      kind = 'file',
      path = target.path,
      range = {
        line = action_line,
        start_col = 0,
        end_col = line_content and #line_content or 0,
      },
    })
  end

  local start_line = output:get_line_count() + 1
  if not (config.ui.output.tools.show_output or config.ui.output.tools.use_folds) then
    return
  end

  local change = part.changes and part.changes[1]
  if tool_type == 'edit' and change and change.diff then
    utils.format_diff(output, change.diff, file_type, change.path)
  elseif tool_type == 'write' and target.content then
    utils.format_code(output, vim.split(target.content, '\n'), file_type)
  end

  output:add_fold_with_threshold(start_line, config.ui.output.tools.show_output, config.ui.output.tools.use_folds)
end

---@param part table
---@return string, string, string
function M.summary(part)
  local tool = part.name
  if tool == 'read' then
    return icons.get('read'), 'read', resolve_display_file_name(part.target and part.target.path, '')
  end
  return icons.get(tool), tool, resolve_file_name(part.target and part.target.path)
end

return M
