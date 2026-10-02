local assert = require('luassert')

local M = {}

---@param snapshot table
---@return table
local function normalized(snapshot)
  local copy = vim.deepcopy(snapshot)
  ---@type string[]
  local lines = snapshot.lines
  local fence, first_line
  for index, line in ipairs(lines) do
    if fence then
      if line == fence then
        local content = table.concat(vim.list_slice(lines, first_line, index - 1), '\n')
        local ok, decoded = pcall(vim.json.decode, content)
        if ok then
          -- Keep line positions so extmark/action comparisons remain exact.
          for content_index = first_line, index - 1 do
            copy.lines[content_index] = false
          end
          copy.lines[first_line] = { json = decoded }
        end
        fence, first_line = nil, nil
      end
    else
      fence = line:match('^(```+)json$')
      if fence then
        first_line = index + 1
      end
    end
  end
  return copy
end

---Compare valid fenced JSON structurally; all other snapshot fields remain exact.
---@param expected table
---@param actual table
function M.assert_same(expected, actual)
  assert.same(normalized(expected), normalized(actual))
end

return M
