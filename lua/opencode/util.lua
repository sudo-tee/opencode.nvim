local Path = require('plenary.path')
local M = {}

function M.template(str, vars)
  return (str:gsub('{(.-)}', function(key)
    return tostring(vars[key] or '')
  end))
end

function M.uid()
  return tostring(os.time()) .. '-' .. tostring(math.random(1000, 9999))
end

function M.is_current_buf_a_file()
  local bufnr = vim.api.nvim_get_current_buf()
  local buftype = vim.bo[bufnr].buftype
  local filepath = vim.fn.expand('%:p')

  -- Valid files have empty buftype
  -- This excludes special buffers like help, terminal, nofile, etc.
  return buftype == '' and filepath ~= ''
end

function M.indent_code_block(text)
  if not text then
    return nil
  end
  local lines = vim.split(text, '\n', { plain = true })

  local first, last = nil, nil
  for i, line in ipairs(lines) do
    if line:match('[^%s]') then
      first = first or i
      last = i
    end
  end

  if not first then
    return ''
  end

  local content = {}
  for i = first, last do
    table.insert(content, lines[i])
  end

  local min_indent = math.huge
  for _, line in ipairs(content) do
    if line:match('[^%s]') then
      min_indent = math.min(min_indent, line:match('^%s*'):len())
    end
  end

  if min_indent < math.huge and min_indent > 0 then
    for i, line in ipairs(content) do
      if line:match('[^%s]') then
        content[i] = line:sub(min_indent + 1)
      end
    end
  end

  return vim.trim(table.concat(content, '\n'))
end

-- Get timezone offset in seconds for various timezone formats
function M.get_timezone_offset(timezone)
  -- Handle numeric timezone formats (+HHMM, -HHMM)
  if timezone:match('^[%+%-]%d%d:?%d%d$') then
    local sign = timezone:sub(1, 1) == '+' and 1 or -1
    local hours = tonumber(timezone:match('^[%+%-](%d%d)'))
    local mins = tonumber(timezone:match('^[%+%-]%d%d:?(%d%d)$') or '00')
    return sign * (hours * 3600 + mins * 60)
  end

  -- Map of common timezone abbreviations to their offset in seconds from UTC
  local timezone_map = {
    -- Zero offset timezones
    ['UTC'] = 0,
    ['GMT'] = 0,

    -- North America
    ['EST'] = -5 * 3600,
    ['EDT'] = -4 * 3600,
    ['CST'] = -6 * 3600,
    ['CDT'] = -5 * 3600,
    ['MST'] = -7 * 3600,
    ['MDT'] = -6 * 3600,
    ['PST'] = -8 * 3600,
    ['PDT'] = -7 * 3600,
    ['AKST'] = -9 * 3600,
    ['AKDT'] = -8 * 3600,
    ['HST'] = -10 * 3600,

    -- Europe
    ['WET'] = 0,
    ['WEST'] = 1 * 3600,
    ['CET'] = 1 * 3600,
    ['CEST'] = 2 * 3600,
    ['EET'] = 2 * 3600,
    ['EEST'] = 3 * 3600,
    ['MSK'] = 3 * 3600,
    ['BST'] = 1 * 3600,

    -- Asia & Middle East
    ['IST'] = 5.5 * 3600,
    ['PKT'] = 5 * 3600,
    ['HKT'] = 8 * 3600,
    ['PHT'] = 8 * 3600,
    ['JST'] = 9 * 3600,
    ['KST'] = 9 * 3600,

    -- Australia & Pacific
    ['AWST'] = 8 * 3600,
    ['ACST'] = 9.5 * 3600,
    ['AEST'] = 10 * 3600,
    ['AEDT'] = 11 * 3600,
    ['NZST'] = 12 * 3600,
    ['NZDT'] = 13 * 3600,
  }

  -- Handle special cases for ambiguous abbreviations
  if timezone == 'CST' and not timezone_map[timezone] then
    -- In most contexts, CST refers to Central Standard Time (US)
    return -6 * 3600
  end

  -- Return the timezone offset or default to UTC (0)
  return timezone_map[timezone] or 0
end

-- Reset all ANSI styling
function M.ansi_reset()
  return '\27[0m'
end

---Remove ANSI escape sequences
---@param str string: Input string containing ANSI escape codes
---@return string stripped_str
function M.strip_ansi(str)
  return (str:gsub('\27%[[%d;]*m', ''))
end

---Replace markdown codeblock markers with ` ` `
---@param str string: Input string
---@return string replaced_str
function M.replace_markdown_codefences(str)
  return (str:gsub('```', '` ` `'))
end

---Strip ANSI escape sequences from all lines
---@param lines table
---@return table stripped_lines
function M.sanitize_lines(lines)
  local stripped_lines = {}
  for _, line in pairs(lines) do
    -- vim.notify(line)
    table.insert(stripped_lines, M.replace_markdown_codefences(M.strip_ansi(line)))
  end

  return stripped_lines
end

--- Convert a datetime to a human-readable "time ago" format
--- @param timestamp number
--- @return string: Human-readable time ago string (e.g., "2 hours ago")
function M.time_ago(timestamp)
  if timestamp > 1e12 then
    timestamp = math.floor(timestamp / 1000)
  end

  local now = os.time()
  local diff = now - timestamp
  if diff < 0 then
    return 'in the future'
  elseif diff < 60 then
    return 'just now'
  elseif diff < 3600 then
    local mins = math.floor(diff / 60)
    return mins == 1 and '1 minute ago' or mins .. ' minutes ago'
  elseif diff < 86400 then
    local hours = math.floor(diff / 3600)
    return hours == 1 and '1 hour ago' or hours .. ' hours ago'
  elseif diff < 604800 then
    local days = math.floor(diff / 86400)
    return days == 1 and '1 day ago' or days .. ' days ago'
  elseif diff < 2592000 then
    local weeks = math.floor(diff / 604800)
    return weeks == 1 and '1 week ago' or weeks .. ' weeks ago'
  elseif diff < 31536000 then
    local months = math.floor(diff / 2592000)
    return months == 1 and '1 month ago' or months .. ' months ago'
  else
    local years = math.floor(diff / 31536000)
    return years == 1 and '1 year ago' or years .. ' years ago'
  end
end

function M.index_of(tbl, value)
  for i, v in ipairs(tbl) do
    if v == value then
      return i
    end
  end
  return nil
end

local _is_git_project = nil
function M.is_git_project()
  if _is_git_project ~= nil then
    return _is_git_project
  end
  local git_dir = Path:new(vim.fn.getcwd()):joinpath('.git')
  _is_git_project = git_dir:exists()
  return _is_git_project
end

function M.format_number(n)
  if not n or n <= 0 then
    return nil
  end

  if n >= 1e6 then
    return string.format('%.1fM', n / 1e6)
  elseif n >= 1e3 then
    return string.format('%.1fK', n / 1e3)
  else
    return tostring(n)
  end
end

function M.format_percentage(n)
  return n and n > 0 and string.format('%.1f%%', n * 100) or nil
end

function M.format_cost(c)
  return c and c > 0 and string.format('$%.2f', c) or nil
end

function M.debounce(func, delay)
  local timer = nil
  return function(...)
    if timer then
      timer:stop()
    end
    local args = { ... }
    timer = vim.defer_fn(function()
      func(unpack(args))
    end, delay or 100)
  end
end

---@param dir string Directory path to read JSON files from
---@param max_items? number Maximum number of items to read
---@return table[]|nil Array of decoded JSON objects
function M.read_json_dir(dir, max_items)
  if not dir or vim.fn.isdirectory(dir) == 0 then
    return nil
  end

  local count = 0
  local decoded_items = {}
  for file, file_type in vim.fs.dir(dir) do
    if file_type == 'file' and file:match('%.json$') then
      local file_ok, content = pcall(vim.fn.readfile, dir .. '/' .. file)
      if file_ok then
        local lines = table.concat(content, '\n')
        local ok, data = pcall(vim.json.decode, lines)
        if ok and data then
          table.insert(decoded_items, data)
        end
      end
    end
    count = count + 1
    if max_items and count >= max_items then
      break
    end
  end

  if #decoded_items == 0 then
    return nil
  end
  return decoded_items
end

--- Safely call a function if it exists.
--- @param fn function|nil
--- @param ... any
function M.safe_call(fn, ...)
  local arg = { ... }
  return fn and vim.schedule(function()
    fn(unpack(arg))
  end)
end

---@param version string
---@return number|nil, number|nil, number|nil
function M.parse_semver(version)
  if not version or version == '' then
    return nil
  end
  local major, minor, patch = version:match('(%d+)%.(%d+)%.?(%d*)')
  if not major then
    return nil
  end
  return tonumber(major) or 0, tonumber(minor) or 0, tonumber(patch) or 0
end

---@param version string
---@param required_version string
---@return boolean
function M.is_version_greater_or_equal(version, required_version)
  local major, minor, patch = M.parse_semver(version)
  local req_major, req_minor, req_patch = M.parse_semver(required_version)
  if not major or not req_major then
    return false
  end
  if major ~= req_major then
    return major > req_major
  end
  if minor ~= req_minor then
    return minor > req_minor
  end
  return patch >= req_patch
end

function M.read_file_content(filepath, with_lines_numbers)
  with_lines_numbers = with_lines_numbers or false
  if not filepath or vim.fn.filereadable(filepath) ~= 1 then
    return nil
  end
  local ok, content = pcall(vim.fn.readfile, filepath)
  if not ok or not content then
    return nil
  end
  if with_lines_numbers then
    for i, line in ipairs(content) do
      content[i] = string.format('%06d | %s', i, line)
    end
  end
  return table.concat(content, '\n')
end

--- Parse arguments in the form of key=value, supporting dot notation for nested tables.
--- Example: "context.selection.enabled=false options
--- @param args_str string
--- @return table
function M.parse_dot_args(args_str)
  local result = {}
  for arg in string.gmatch(args_str, '[^%s]+') do
    local key, value = arg:match('([^=]+)=([^=]+)')
    if key and value then
      local parts = vim.split(key, '.', { plain = true })
      local t = result
      for i = 1, #parts - 1 do
        t[parts[i]] = t[parts[i]] or {}
        t = t[parts[i]]
      end
      if value == 'true' then
        value = true
      elseif value == 'false' then
        value = false
      elseif tonumber(value) then
        value = tonumber(value)
      end
      t[parts[#parts]] = value
    end
  end
  return result
end

return M
