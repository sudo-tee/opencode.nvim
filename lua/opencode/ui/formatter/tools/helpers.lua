local M = {}

---@param file_path string
---@return string
function M.resolve_file_name(file_path)
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
function M.is_directory_path(file_path, tool_output)
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
function M.resolve_display_file_name(file_path, tool_output)
  local resolved = M.resolve_file_name(file_path)

  if resolved ~= '' and M.is_directory_path(file_path, tool_output) and not vim.endswith(resolved, '/') then
    resolved = resolved .. '/'
  end

  return resolved
end

---@param input GrepToolInput|nil
---@return string
function M.resolve_grep_string(input)
  if not input then
    return ''
  end
  local path_part = input.path or input.include or ''
  local pattern_part = input.pattern or ''
  return table.concat(
    vim.tbl_filter(function(p)
      return p ~= nil and p ~= ''
    end, { path_part, pattern_part }),
    ' '
  )
end

return M
