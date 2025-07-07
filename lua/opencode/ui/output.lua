local Output = {}
Output.__index = Output

---@class Output
---@field lines table<number, string>
---@field metadata table<number, table>
---@return self Output
function Output.new()
  local self = setmetatable({}, Output)
  self.lines = {}
  self.metadata = {}
  return self
end

---Add a new line with optional metadata
---@param line string
---@param metadata? table
---@return number index The index of the added line
function Output:add_line(line, metadata)
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
---@return number[] indices The indices of the added lines
function Output:add_lines(lines, metadata, prefix)
  local indices = {}
  for _, line in ipairs(lines) do
    prefix = prefix or ''
    local idx = self:add_line(prefix .. line, metadata)
    table.insert(indices, idx)
  end
  return indices
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

function Output:clear()
  self.lines = {}
  self.metadata = {}
end

---Get all lines as a table
---@return string[]
function Output:get_lines()
  return vim.deepcopy(self.lines)
end

return Output
