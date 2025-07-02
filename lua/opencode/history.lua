local M = {}

local Path = require('plenary.path')
local cached_history = nil
local prompt_before_history = nil

M.index = nil

local function get_history_file()
  local data_path = Path:new(vim.fn.stdpath('data')):joinpath('opencode')
  if not data_path:exists() then
    data_path:mkdir({ parents = true })
  end
  return data_path:joinpath('history.txt')
end

M.write = function(prompt)
  local file = io.open(get_history_file().filename, "a")
  if file then
    -- Escape any newlines in the prompt
    local escaped_prompt = prompt:gsub("\n", "\\n")
    file:write(escaped_prompt .. "\n")
    file:close()
    -- Invalidate cache when writing new history
    cached_history = nil
  end
end

M.read = function()
  -- Return cached result if available
  if cached_history then
    return cached_history
  end

  local line_by_index = {}
  local file = io.open(get_history_file().filename, "r")

  if file then
    local lines = {}

    -- Read all non-empty lines
    for line in file:lines() do
      if line:gsub("%s", "") ~= "" then
        -- Unescape any escaped newlines
        local unescaped_line = line:gsub("\\n", "\n")
        table.insert(lines, unescaped_line)
      end
    end
    file:close()

    -- Reverse the array to have index 1 = most recent
    for i = 1, #lines do
      line_by_index[i] = lines[#lines - i + 1]
    end
  end

  -- Cache the result
  cached_history = line_by_index
  return line_by_index
end

M.prev = function()
  local history = M.read()

  if not M.index or M.index == 0 then
    prompt_before_history = require('opencode.state').input_content
  end

  -- Initialize or increment index
  M.index = (M.index or 0) + 1

  -- Cap at the end of history
  if M.index > #history then
    M.index = #history
  end

  return history[M.index]
end

M.next = function()
  -- Return nil for invalid cases
  if not M.index then
    return nil
  end

  if M.index <= 1 then
    M.index = nil
    return prompt_before_history
  end

  M.index = M.index - 1
  return M.read()[M.index]
end

return M
