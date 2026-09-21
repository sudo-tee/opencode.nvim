local util = require('opencode.util')
local icons = require('opencode.ui.icons')

local M = {}

---@class OpencodePatchFile
---@field operation 'Add'|'Update'|'Delete'
---@field path string
---@field lines string[]

---@param patch_text string
---@return OpencodePatchFile[]
local function patch_files(patch_text)
  local files = {}
  local current
  for _, line in ipairs(vim.split(patch_text, '\n')) do
    local operation, path = line:match('^%*%*%* (%w+) File: (.+)$')
    if operation ~= 'Update' and operation ~= 'Add' and operation ~= 'Delete' then
      path = nil
    end
    if path then
      current = { operation = operation, path = path, lines = {} }
      files[#files + 1] = current
    elseif current and line:match('^%*%*%* Move to: (.+)$') then
      current.path = line:match('^%*%*%* Move to: (.+)$')
    elseif current and line ~= '*** Begin Patch' and line ~= '*** End Patch' then
      current.lines[#current.lines + 1] = line
    end
  end
  return files
end

---@param haystack string[]
---@param needle string[]
---@return integer|nil
---@param file OpencodePatchFile
---@return string|nil
local function unified_diff(file)
  if file.operation == 'Delete' and #file.lines == 0 then
    return nil
  end

  local old_path = file.operation == 'Add' and '/dev/null' or 'a/' .. file.path
  local new_path = file.operation == 'Delete' and '/dev/null' or 'b/' .. file.path
  local lines = {
    string.format('diff --git a/%s b/%s', file.path, file.path),
    'index 0000000..0000000 100644',
    '--- ' .. old_path,
    '+++ ' .. new_path,
  }

  if file.operation == 'Add' then
    lines[#lines + 1] = string.format('@@ -0,0 +1,%d @@', #file.lines)
  elseif file.lines[1] == nil or not file.lines[1]:match('^@@') then
    lines[#lines + 1] = '@@'
  end
  vim.list_extend(lines, file.lines)
  return table.concat(lines, '\n')
end

---@param output Output
---@param part table
function M.format(output, part)
  local formatter_utils = require('opencode.ui.formatter.utils')
  local config = require('opencode.config')
  local patch_text = part.input and part.input.patchText
  local files = {}
  if type(part.changes) == 'table' and #part.changes > 0 then
    for _, change in ipairs(part.changes) do
      files[#files + 1] = { path = change.path, diff = change.diff }
    end
  elseif type(patch_text) == 'string' then
    files = patch_files(patch_text)
  end

  if #files == 0 then
    formatter_utils.format_action(
      output,
      icons.get('edit'),
      'apply patch',
      part.input and (part.input.description or part.input.filePath) or '',
      formatter_utils.get_duration_text(part)
    )
    return
  end

  for _, file in ipairs(files) do
    formatter_utils.format_action(
      output,
      icons.get('edit'),
      'apply patch',
      file.path,
      formatter_utils.get_duration_text(part)
    )
    local action_line = output:get_line_count()
    local action_text = output:get_line(action_line)
    output:add_target({
      kind = 'file',
      path = file.path,
      range = { line = action_line, start_col = 0, end_col = action_text and #action_text or 0 },
    })

    if config.ui.output.tools.show_output or config.ui.output.tools.use_folds then
      local diff = file.diff or unified_diff(file)
      if diff then
        local start_line = output:get_line_count() + 1
        formatter_utils.format_diff(output, diff, util.get_markdown_filetype(file.path), file.path)
        output:add_fold_with_threshold(start_line, config.ui.output.tools.show_output, config.ui.output.tools.use_folds)
      end
    end
  end
end

---@param part table
---@return string, string, string
function M.summary(part)
  local patch_text = part.input and part.input.patchText
  local files = type(patch_text) == 'string' and patch_files(patch_text) or {}
  local file = files[1]
  local suffix = #files > 1 and string.format(' (+%d more)', #files - 1) or ''
  return icons.get('edit'), 'apply patch', file and file.path .. suffix or ''
end

return M
