---Shared diff primitives over `Output` for the renderer pipeline.

local M = {}

---@param mark OutputExtmark|fun(): OutputExtmark
---@return OutputExtmark
local function resolve_mark(mark)
  return type(mark) == 'function' and mark() or mark
end

---@param a (OutputExtmark|fun(): OutputExtmark)[]|nil
---@param b (OutputExtmark|fun(): OutputExtmark)[]|nil
---@return boolean
local function marks_equal(a, b)
  a = a or {}
  b = b or {}
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if not vim.deep_equal(resolve_mark(a[i]), resolve_mark(b[i])) then
      return false
    end
  end
  return true
end

---Negative keys (line_idx < 0) are header virt_text; any disagreement
---forces the prefix to 0.
---@param previous_formatted Output|nil
---@param formatted_data Output|nil
---@return integer
function M.unchanged_prefix_extmarks(previous_formatted, formatted_data)
  local previous_extmarks = previous_formatted and previous_formatted.extmarks or {}
  local next_extmarks = formatted_data and formatted_data.extmarks or {}

  for line_idx in pairs(previous_extmarks) do
    if line_idx < 0 and not marks_equal(previous_extmarks[line_idx], next_extmarks[line_idx]) then
      return 0
    end
  end
  for line_idx in pairs(next_extmarks) do
    if line_idx < 0 and not marks_equal(previous_extmarks[line_idx], next_extmarks[line_idx]) then
      return 0
    end
  end

  local previous_lines = previous_formatted and previous_formatted.lines or {}
  local next_lines = formatted_data and formatted_data.lines or {}
  local max_lines = math.max(#previous_lines, #next_lines)
  local prefix_len = 0
  for line_idx = 0, max_lines - 1 do
    if not marks_equal(previous_extmarks[line_idx], next_extmarks[line_idx]) then
      break
    end
    prefix_len = line_idx + 1
  end
  return prefix_len
end

---@param previous_formatted Output|nil
---@param formatted_data Output|nil
---@return integer
function M.unchanged_prefix_lines(previous_formatted, formatted_data)
  local previous_lines = previous_formatted and previous_formatted.lines or {}
  local next_lines = formatted_data and formatted_data.lines or {}
  local prefix_len = 0
  for i = 1, math.min(#previous_lines, #next_lines) do
    if previous_lines[i] ~= next_lines[i] then
      break
    end
    prefix_len = i
  end
  return prefix_len
end

---@param formatted Output|nil
---@return integer|nil
function M.min_extmark_line(formatted)
  local min_line
  for line_idx in pairs(formatted and formatted.extmarks or {}) do
    if min_line == nil or line_idx < min_line then
      min_line = line_idx
    end
  end
  return min_line
end

---@param formatted Output|nil
---@param fallback integer
---@return integer
function M.max_extmark_line(formatted, fallback)
  local max_line = fallback
  for line_idx in pairs(formatted and formatted.extmarks or {}) do
    if line_idx > max_line then
      max_line = line_idx
    end
  end
  return max_line
end

---@param lines string[]|nil
---@param start_idx integer
---@return string[]
function M.slice_lines(lines, start_idx)
  local slice = {}
  for i = start_idx, #(lines or {}) do
    slice[#slice + 1] = lines[i]
  end
  return slice
end

---Preserves negative keys untouched, shifts non-negative keys by -start_line.
---@param extmarks table<number, OutputExtmark[]>|nil
---@param start_line integer
---@return table<number, OutputExtmark[]>
function M.slice_extmarks(extmarks, start_line)
  local slice = {}
  for line_idx, marks in pairs(extmarks or {}) do
    if line_idx < 0 then
      slice[line_idx] = vim.deepcopy(marks)
    elseif line_idx >= start_line then
      slice[line_idx - start_line] = vim.deepcopy(marks)
    end
  end
  return slice
end

---@param previous Output|nil
---@param formatted Output|nil
---@return boolean
function M.is_unchanged(previous, formatted)
  if not previous or not formatted or #previous.lines ~= #formatted.lines then
    return false
  end
  if M.unchanged_prefix_lines(previous, formatted) ~= #previous.lines then
    return false
  end
  for line, marks in pairs(previous.extmarks or {}) do
    if not marks_equal(marks, (formatted.extmarks or {})[line]) then
      return false
    end
  end
  for line, marks in pairs(formatted.extmarks or {}) do
    if not marks_equal(marks, (previous.extmarks or {})[line]) then
      return false
    end
  end
  return true
end

---@param old_lines string[]
---@param new_lines string[]
---@return boolean
function M.is_append_only(old_lines, new_lines)
  if #new_lines <= #old_lines then
    return false
  end
  local prefix_len = M.unchanged_prefix_lines({ lines = old_lines }, { lines = new_lines })
  return prefix_len == #old_lines
end

return M