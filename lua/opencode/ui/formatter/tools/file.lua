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
---@param part OpencodeMessagePart
function M.format(output, part)
  local input = part.state and part.state.input or {}
  local metadata = part.state and part.state.metadata or {}
  local tool_output = part.state and part.state.output or ''
  local tool_type = part.tool

  local file_name = tool_type == 'read' and resolve_display_file_name(input.filePath or '', tool_output)
    or resolve_file_name(input.filePath or '')

  local file_type = input.filePath and util.get_markdown_filetype(input.filePath) or ''

  local utils = require('opencode.ui.formatter.utils')
  local config = require('opencode.config')

  local icons = require('opencode.ui.icons')
  utils.format_action(output, icons.get(tool_type), tool_type, file_name, utils.get_duration_text(part))

  local start_line = output:get_line_count() + 1
  if not (config.ui.output.tools.show_output or config.ui.output.tools.use_folds) then
    return
  end

  if tool_type == 'edit' and metadata.diff then
    utils.format_diff(output, metadata.diff, file_type)
  elseif tool_type == 'write' and input.content then
    utils.format_code(output, vim.split(input.content, '\n'), file_type)
  end

  output:add_fold_with_threshold(start_line, config.ui.output.tools.show_output, config.ui.output.tools.use_folds)
end

---@param part OpencodeMessagePart
---@param input FileToolInput
---@return string, string, string
function M.summary(part, input)
  local tool = part.tool
  if tool == 'read' then
    local tool_output = part.state and part.state.output or nil
    return icons.get('read'), 'read', resolve_display_file_name(input.filePath, tool_output)
  end
  return icons.get(tool), tool, resolve_file_name(input.filePath)
end

return M
