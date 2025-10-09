local state = require('opencode.state')
local config = require('opencode.config')
local Output = {}
Output.__index = Output

---@class Output
---@field lines table<number, string>
---@field metadata table<number, OutputMetadata>
---@field extmarks table<number, OutputExtmark> -- Stores extmarks for each line
---@field actions table<number, OutputAction[]> -- Stores contextual actions for each line range
---@return self Output
function Output.new()
  local self = setmetatable({}, Output)
  self.lines = {}
  self.metadata = {}
  self.extmarks = {}
  self.actions = {}
  return self
end

---Add a new line
---@param line string
---@param fit? boolean Optional parameter to control line fitting
---@return number index The index of the added line
function Output:add_line(line, fit)
  local win_width = state.windows and vim.api.nvim_win_get_width(state.windows.output_win) or config.ui.window_width
  if fit and #line > win_width then
    line = vim.fn.strcharpart(line, 0, win_width - 7) .. '...'
  end
  table.insert(self.lines, line)
  return #self.lines
end

---Get line by index
---@param idx number
---@return string?
function Output:get_line(idx)
  return self.lines[idx]
end

---Get metadata for line
---@param idx number
---@return OutputMetadata|nil
function Output:get_metadata(idx)
  if not self.metadata[idx] then
    return nil
  end
  return vim.deepcopy(self.metadata[idx])
end

---@param idx number
---@param predicate? fun(metadata: OutputMetadata): boolean Optional predicate to filter metadata
---@param direction? 'next'|'previous' Optional direction to search for metadata
---@return OutputMetadata|nil
function Output:get_nearest_metadata(idx, predicate, direction)
  local step = direction == 'next' and 1 or -1
  local limit = step == 1 and #self.lines or 1
  for i = idx, limit, step do
    local metadata = self.metadata[i]
    if predicate and metadata then
      if predicate(metadata) then
        return vim.deepcopy(metadata)
      end
    elseif not predicate and metadata then
      return vim.deepcopy(metadata)
    end
  end
end

---Get metadata for all lines
---@return OutputMetadata[]
function Output:get_all_metadata()
  return vim.deepcopy(self.metadata or {})
end

---@param line number Buffer line number
---@return string|nil Snapshot commit hash if available
function Output:get_previous_snapshot(line)
  local metadata = self:get_nearest_metadata(line, function(metadata)
    return metadata.snapshot ~= nil
  end, 'previous')
  return metadata and metadata.snapshot or nil
end

---@param line number Buffer line number
---@return string|nil Snapshot commit hash if available
function Output:get_next_snapshot(line)
  local metadata = self:get_nearest_metadata(line, function(metadata)
    return metadata.snapshot ~= nil
  end, 'next')
  return metadata and metadata.snapshot or nil
end

---@return string|nil Snapshot commit hash if available
function Output:get_first_snapshot()
  local metadata = self:get_nearest_metadata(1, function(metadata)
    return metadata.snapshot ~= nil
  end, 'next')
  return metadata and metadata.snapshot or nil
end

---@return string|nil Snapshot commit hash if available
function Output:get_last_snapshot()
  local metadata = self:get_nearest_metadata(#self.lines, function(metadata)
    return metadata.snapshot ~= nil
  end, 'previous')
  return metadata and metadata.snapshot or nil
end

---Merge text into an existing line
---@param idx number
---@param text string
function Output:merge_line(idx, text)
  if self.lines[idx] then
    self.lines[idx] = self.lines[idx] .. text
  end
end

---Add multiple lines
---@param lines string[]
---@param prefix? string Optional prefix for each line
function Output:add_lines(lines, prefix)
  for _, line in ipairs(lines) do
    prefix = prefix or ''

    if line == '' then
      self:add_empty_line()
    else
      self:add_line(prefix .. line)
    end
  end
end

---Add an empty line if the last line is not empty
---@return number? index The index of the added line, or nil if no line was added
function Output:add_empty_line()
  local last_line = self.lines[#self.lines]
  if not last_line or last_line ~= '' then
    return self:add_line('')
  end
  return nil
end

---Add metadata to the last line
---@param metadata OutputMetadata
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
  self.actions = {}
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
---@param extmark OutputExtmark|fun(): OutputExtmark  The extmark data or a function returning it
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

---Add contextual actions
---@param actions OutputAction[] The actions to add
function Output:add_actions(actions)
  for _, action in ipairs(actions) do
    table.insert(self.actions, action)
  end
end

---Add contextual action
---@param action OutputAction The actions to add
function Output:add_action(action)
  if not action.display_line then
    action.display_line = #self.lines - 1
  end
  if not action.range then
    action.range = { from = #self.lines, to = #self.lines }
  end
  table.insert(self.actions, action)
end

---Get actions for a line matching a range
---@param line number The line index to check
---@return OutputAction[]|nil
function Output:get_actions_for_line(line)
  local actions = {}
  for _, action in pairs(self.actions) do
    if not action.range then
      if line == action.display_line then
        table.insert(actions, vim.deepcopy(action))
      end
    elseif action.range then
      if line >= action.range.from and line <= action.range.to then
        table.insert(actions, vim.deepcopy(action))
      end
    end
  end
  return #actions > 0 and actions or nil
end

return Output
