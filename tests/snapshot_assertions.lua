local assert = require('luassert')

local M = {}

local function normalize_json_slashes(line)
  if not line:match('^%s*[%[{]') or not pcall(vim.json.decode, line) then
    return line
  end
  -- Older Neovim encoders escape slashes even in single-line tool input dumps.
  -- An even backslash run encodes a literal backslash, not an escaped slash.
  return (
    line:gsub('(\\+)/', function(backslashes)
      return (#backslashes % 2 == 1 and backslashes:sub(2) or backslashes) .. '/'
    end)
  )
end

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
      else
        copy.lines[index] = normalize_json_slashes(line)
      end
    end
  end
  return copy
end

---Compare fenced JSON structurally and equivalent inline JSON slash escaping.
---All other snapshot fields remain exact.
---@param expected table
---@param actual table
function M.assert_same(expected, actual)
  assert.same(normalized(expected), normalized(actual))
end

return M
