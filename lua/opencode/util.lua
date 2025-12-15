local Path = require('plenary.path')
local v = require('jit.v')
local M = {}

function M.uid()
  return tostring(os.time()) .. '-' .. tostring(math.random(1000, 9999))
end

function M.is_buf_a_file(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local buftype = vim.bo[bufnr].buftype
  local filepath = vim.api.nvim_buf_get_name(bufnr)

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

---Strip ANSI escape sequences from all lines
---@param lines table
---@return table stripped_lines
function M.sanitize_lines(lines)
  local stripped_lines = {}
  for _, line in pairs(lines) do
    table.insert(stripped_lines, M.strip_ansi(line))
  end

  return stripped_lines
end

--- Format a timestamp as time (e.g., "10:23 AM",  "13 Oct 03:32 PM"  "13 Oct 2025 03:32 PM")
--- @param timestamp number
--- @return string: Formatted time string
function M.format_time(timestamp)
  local formats = { day = '%I:%M %p', year = '%d %b %I:%M %p', full = '%d %b %Y %I:%M %p' }

  if timestamp > 1e12 then
    timestamp = math.floor(timestamp / 1000)
  end

  local same_day = os.date('%Y-%m-%d') == os.date('%Y-%m-%d', timestamp)
  local same_year = os.date('%Y') == os.date('%Y', timestamp)

  local format_str = same_day and formats.day or (same_year and formats.year or formats.full)

  return os.date(format_str, timestamp) --[[@as string]]
end

function M.index_of(tbl, value)
  for i, v in ipairs(tbl) do
    if v == value then
      return i
    end
  end
  return nil
end

function M.find_index_of(tbl, predicate)
  for i, v in ipairs(tbl) do
    if predicate(v) then
      return i
    end
  end
  return nil
end

function M.some(tbl, predicate)
  for _, v in ipairs(tbl) do
    if predicate(v) then
      return true
    end
  end
  return false
end

local _is_git_project = nil
function M.is_git_project()
  if _is_git_project ~= nil then
    return _is_git_project
  end
  local cwd = vim.fn.getcwd()
  if not cwd then
    _is_git_project = false
    return _is_git_project
  end
  local git_dir = Path:new(cwd):joinpath('.git')
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
      -- Convert string values to appropriate types
      local parsed_value = value
      if value == 'true' then
        parsed_value = true
      elseif value == 'false' then
        parsed_value = false
      elseif tonumber(value) then
        parsed_value = tonumber(value)
      end
      t[parts[#parts]] = parsed_value
    end
  end
  return result
end

--- Check if prompt is allowed via guard callback
--- @param guard_callback? function
--- @param mentioned_files? string[] List of mentioned files in the context
--- @return boolean allowed
--- @return string|nil error_message
function M.check_prompt_allowed(guard_callback, mentioned_files)
  if not guard_callback then
    return true, nil -- No guard = always allowed
  end

  if not type(guard_callback) == 'function' then
    return false, 'prompt_guard must be a function'
  end

  mentioned_files = mentioned_files or {}
  local success, result = pcall(guard_callback, mentioned_files)

  if not success then
    return false, 'prompt_guard error: ' .. tostring(result)
  end

  if type(result) ~= 'boolean' then
    return false, 'prompt_guard must return a boolean'
  end

  ---@cast result boolean
  return result, nil
end

--- Get the markdown type to use based on the filename. First gets the neovim type
--- for the file. Then apply any specific overrides. Falls back to using the file
--- extension if nothing else matches
--- @param filename string filename, possibly including path
--- @return string markdown_filetype
function M.get_markdown_filetype(filename)
  if not filename or filename == '' then
    return ''
  end

  local file_type_overrides = {
    javascriptreact = 'jsx',
    typescriptreact = 'tsx',
    sh = 'bash',
    yaml = 'yml',
    text = 'txt', -- nvim 0.12-nightly returns text as the type which breaks our unit tests
  }

  local file_type = vim.filetype.match({ filename = filename }) or ''

  if file_type_overrides[file_type] then
    return file_type_overrides[file_type]
  end

  if file_type and file_type ~= '' then
    return file_type
  end

  return vim.fn.fnamemodify(filename, ':e')
end

function M.strdisplaywidth(str)
  local str = str:gsub('%%#.-#', ''):gsub('%%[%*]', '')
  return vim.fn.strdisplaywidth(str)
end

--- Parse run command arguments with optional agent, model, and context prefixes.
--- Returns opts table and remaining prompt string.
--- Format: [agent=<name>] [model=<model>] [context=<key=value,...>] <prompt>
--- Also supports quick context syntax like "#buffer #git_diff" in the prompt
--- @param args string[]
--- @return table opts, string prompt
function M.parse_run_args(args)
  local opts = {}
  local prompt_start_idx = 1

  for i, token in ipairs(args) do
    local agent = token:match('^agent=(.+)$')
    local model = token:match('^model=(.+)$')
    local context = token:match('^context=(.+)$')

    if agent then
      opts.agent = agent
      prompt_start_idx = i + 1
    elseif model then
      opts.model = model
      prompt_start_idx = i + 1
    elseif context then
      opts.context = M.parse_dot_args(context:gsub(',', ' '))
      prompt_start_idx = i + 1
    else
      break
    end
  end

  local prompt_tokens = vim.list_slice(args, prompt_start_idx)
  local prompt = table.concat(prompt_tokens, ' ')

  if prompt:find('#') then
    local cleaned_prompt, quick_context = M.parse_quick_context_args(prompt)
    prompt = cleaned_prompt

    opts.context = vim.tbl_deep_extend('force', opts.context or {}, quick_context) --[[@as OpencodeContextConfig]]
  end

  return opts, prompt
end

---pcall but returns a full stacktrace on error
function M.pcall_trace(fn, ...)
  return xpcall(fn, function(err)
    return debug.traceback(err, 2)
  end, ...)
end

function M.is_path_in_cwd(path)
  local cwd = vim.fn.getcwd()
  local abs_path = vim.fn.fnamemodify(path, ':p')
  return abs_path:sub(1, #cwd) == cwd
end

--- Check if a given path is in the system temporary directory.
--- Optionally match the filename against a pattern.
--- @param path string File path to check
--- @param pattern string|nil Optional Lua pattern to match the filename
--- @return boolean is_temp
function M.is_temp_path(path, pattern)
  local temp_dir = vim.fn.tempname()
  temp_dir = vim.fn.fnamemodify(temp_dir, ':h')

  local abs_path = vim.fn.fnamemodify(path, ':p')
  if abs_path:sub(1, #temp_dir) ~= temp_dir then
    return false
  end

  if pattern then
    local filename = vim.fn.fnamemodify(path, ':t')
    return filename:match(pattern) ~= nil
  end

  return true
end

--- Parse quick context arguments and extract prompt.
--- Transforms quick context items like "generate a conventional commit #git_diff #buffer"
--- into a partial ContextConfig object with only enabled fields and returns the remaining text as prompt.
--- @param prompt string Context arguments string (e.g., "generate a conventional commit #buffer #git_diff")
--- @return string prompt, OpencodeContextConfig config
function M.parse_quick_context_args(prompt)
  ---@type OpencodeContextConfig
  local config = { enabled = true }

  if not prompt or prompt == '' then
    return '', config
  end

  local function extract(items)
    local found = false
    for _, item in ipairs(items) do
      local pattern = '#' .. item
      local start_pos = prompt:lower():find(pattern:lower(), 1, true)
      if start_pos then
        found = true
        local end_pos = start_pos + #pattern - 1
        prompt = prompt:sub(1, start_pos - 1) .. prompt:sub(end_pos + 1)
      end
    end
    return found
  end

  local cursor_enabled = extract({ 'cursor_data', 'cursor' })
  if cursor_enabled then
    config.cursor_data = { enabled = true, context_lines = 5 }
  end

  local info_enabled = extract({ 'info' })
  local warning_enabled = extract({ 'warnings', 'warning', 'warn' })
  local error_enabled = extract({ 'errors' })

  if info_enabled or warning_enabled or error_enabled then
    config.diagnostics = { enabled = true, only_closest = true }
    if info_enabled then
      config.diagnostics.info = true
    end
    if warning_enabled then
      config.diagnostics.warning = true
    end
    if error_enabled then
      config.diagnostics.error = true
    end
  end

  local current_file_enabled = extract({ 'current_file', 'file' })
  if current_file_enabled then
    config.current_file = { enabled = true }
  end

  local selection_enabled = extract({ 'selection' })
  if selection_enabled then
    config.selection = { enabled = true }
  end

  local agents_enabled = extract({ 'agents' })
  if agents_enabled then
    config.agents = { enabled = true }
  end

  local buffer_enabled = extract({ 'buffer' })
  if buffer_enabled then
    config.buffer = { enabled = true }
  end

  local git_diff_enabled = extract({ 'git_diff', 'diff' })
  if git_diff_enabled then
    config.git_diff = { enabled = true }
  end

  return vim.trim(prompt:gsub('%s+', ' ')), config
end

function M.get_visual_range()
  if not vim.fn.mode():match('[vV\022]') then
    return nil
  end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'nx', true)

  local bufnr = vim.api.nvim_get_current_buf()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")

  local start_line = start_pos[2]
  local start_col = start_pos[3]
  local end_line = end_pos[2]
  local end_col = end_pos[3]

  return {
    bufnr = bufnr,
    start_line = start_line,
    start_col = start_col,
    end_line = end_line,
    end_col = end_col,
  }
end

return M
