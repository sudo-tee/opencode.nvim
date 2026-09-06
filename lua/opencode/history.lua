local M = {}

local cached_history = nil
local prompt_before_history = nil

M.index = nil

local function get_history_file()
  local data_dir = vim.fn.stdpath('data') .. '/opencode'
  if vim.fn.isdirectory(data_dir) ~= 1 then
    vim.fn.mkdir(data_dir, 'p')
  end
  return data_dir .. '/history.txt'
end

---@param prompt string
M.write = function(prompt)
  local history = M.read()
  if #history > 0 and history[1] == prompt then
    return
  end

  local path = get_history_file():gsub('%.txt$', '.jsonl')
  if not vim.uv.fs_stat(path) then
    return M._write_history(vim.list_extend({ prompt }, history))
  end
  local file = io.open(path, 'a')
  if not file then
    return false
  end
  local written = file:write(vim.json.encode(prompt) .. '\n')
  local closed = file:close()
  cached_history = nil
  return written ~= nil and closed ~= nil
end

---@return string[]
M.read = function()
  if cached_history then
    return cached_history
  end

  local legacy_path = get_history_file()
  local file = io.open(legacy_path:gsub('%.txt$', '.jsonl'), 'r')
  local is_json = file ~= nil
  file = file or io.open(legacy_path, 'r')
  local lines = {}
  if file then
    for line in file:lines() do
      if is_json then
        local ok, prompt = pcall(vim.json.decode, line)
        if ok and type(prompt) == 'string' then
          lines[#lines + 1] = prompt
        end
      elseif line:find('%S') then
        -- Legacy records cannot distinguish literal backslashes from escaped newlines.
        lines[#lines + 1] = line:gsub('\\n', '\n')
      end
    end
    file:close()
  end

  cached_history = {}
  for i = #lines, 1, -1 do
    cached_history[#cached_history + 1] = lines[i]
  end
  return cached_history
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

---Delete specific entries from history by their indices
---@param indices number[] Array of 1-based indices to delete
M.delete = function(indices)
  if not indices or #indices == 0 then
    return false
  end

  local history = M.read()
  if #history == 0 then
    return false
  end

  -- Sort indices in descending order to avoid index shifting issues
  local sorted_indices = {}
  local seen = {}
  for _, idx in ipairs(indices) do
    if type(idx) == 'number' and idx % 1 == 0 and idx > 0 and idx <= #history and not seen[idx] then
      seen[idx] = true
      table.insert(sorted_indices, idx)
    end
  end
  table.sort(sorted_indices, function(a, b)
    return a > b
  end)

  history = vim.list_extend({}, history)
  for _, idx in ipairs(sorted_indices) do
    table.remove(history, idx)
  end

  return M._write_history(history)
end

---Clear all history entries
M.clear = function()
  return M._write_history({})
end

---Internal function to write history array to file
---@param history_array table Array of history entries to write
---@return boolean success Whether the write operation succeeded
M._write_history = function(history_array)
  local path = get_history_file():gsub('%.txt$', '.jsonl')
  local lines = {}
  for i = #history_array, 1, -1 do
    lines[#lines + 1] = vim.json.encode(history_array[i])
  end
  local content = #lines > 0 and table.concat(lines, '\n') .. '\n' or ''
  local fd, temp_path = vim.uv.fs_mkstemp(path .. '.XXXXXX')
  if not fd then
    return false
  end
  local written = vim.uv.fs_write(fd, content, 0)
  local closed = vim.uv.fs_close(fd)
  if written ~= #content or not closed or not vim.uv.fs_rename(temp_path, path) then
    vim.uv.fs_unlink(temp_path)
    return false
  end

  cached_history = nil
  M.index = nil
  prompt_before_history = nil
  return true
end

return M
