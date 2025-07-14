local state = require('opencode.state')
local Output = {}
Output.__index = Output

---@class Output
---@field lines table<number, string>
---@field metadata table<number, table>
---@field extmarks table<number, table> -- Stores extmarks for each line
---@return self Output
function Output.new()
  local self = setmetatable({}, Output)
  self.lines = {}
  self.metadata = {}
  self.extmarks = {}
  return self
end

---Add a new line with optional metadata
---@param line string
---@param metadata? table
---@param fit? boolean Optional parameter to control line fitting
---@return number index The index of the added line
function Output:add_line(line, metadata, fit)
  local win_width = vim.api.nvim_win_get_width(state.windows.output_win)
  if fit and #line > win_width then
    line = vim.fn.strcharpart(line, 0, win_width - 7) .. '...'
  end
  table.insert(self.lines, line)
  local idx = #self.lines
  self.metadata[idx] = metadata
  return idx
end

---Get line by index
---@param idx number
---@return string?
function Output:get_line(idx)
  return self.lines[idx]
end

---Get metadata for line
---@param idx number
---@return table?
function Output:get_metadata(idx)
  if not self.metadata[idx] then
    return nil
  end
  return vim.deepcopy(self.metadata[idx])
end

---Get metadata for all lines
---@return table
function Output:get_all_metadata()
  return vim.deepcopy(self.metadata or {})
end

---Merge text into an existing line
---@param idx number
---@param text string
function Output:merge_line(idx, text)
  if self.lines[idx] then
    self.lines[idx] = self.lines[idx] .. text
  end
end

---Add multiple lines with the same metadata
---@param lines string[]
---@param metadata? table
---@param prefix? string Optional prefix for each line
function Output:add_lines(lines, metadata, prefix)
  for _, line in ipairs(lines) do
    prefix = prefix or ''

    if line == '' then
      self:add_empty_line(metadata)
    else
      self:add_line(prefix .. line, metadata)
    end
  end
end

---Add an empty line if the last line is not empty
---@param metadata? table
---@return number? index The index of the added line, or nil if no line was added
function Output:add_empty_line(metadata)
  local last_line = self.lines[#self.lines]
  if not last_line or last_line ~= '' then
    return self:add_line('', metadata)
  end
  return nil
end

---Add metadata to the last line
---@param metadata table
---@return number? index The index of the last line, or nil if no lines exist
function Output:add_metadata(metadata)
  if #self.lines == 0 then
    return nil
  end
  local last_index = #self.lines
  self.metadata[last_index] = metadata
  return last_index
end

---Clear all lines and metadata
function Output:clear()
  self.lines = {}
  self.metadata = {}
  self.extmarks = {}
end

---Get the number of lines
---@return number
function Output:get_line_count()
  return #self.lines
end

---Get all lines as a table
---@return string[]
function Output:get_lines()
  return vim.deepcopy(self.lines)
end

---Add an extmark for a specific line
---@param idx number The line index
---@param extmark table The extmark data {virt_text = {...}, virt_text_pos = '...', etc}
function Output:add_extmark(idx, extmark)
  if not self.extmarks[idx] then
    self.extmarks[idx] = {}
  end
  table.insert(self.extmarks[idx], extmark)
end

---Get all extmarks
---@return table<number, table[]>
function Output:get_extmarks()
  return vim.deepcopy(self.extmarks)
end

return Output
