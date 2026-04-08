local M = {}

---@param old_lines string[]
---@param new_lines string[]
---@return boolean
function M.is_append_only(old_lines, new_lines)
  local old_count = #old_lines
  if #new_lines <= old_count then
    return false
  end

  for i = old_count, 1, -1 do
    if old_lines[i] ~= new_lines[i] then
      return false
    end
  end

  return true
end

---@param old_lines string[]
---@param new_lines string[]
---@return string[]
function M.tail_lines(old_lines, new_lines)
  return vim.list_slice(new_lines, #old_lines + 1, #new_lines)
end

---@param row_offset integer
---@param extmarks table<number, OutputExtmark[]>|nil
---@return table<number, OutputExtmark[]>
function M.tail_extmarks(row_offset, extmarks)
  local tail = {}

  for line_idx, marks in pairs(extmarks or {}) do
    if line_idx >= row_offset then
      tail[line_idx - row_offset] = vim.deepcopy(marks)
    end
  end

  return tail
end

return M
