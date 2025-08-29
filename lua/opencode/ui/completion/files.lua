local M = {}

-- Cache for file results to avoid repeated scans
local file_cache = {}
local cache_timeout = 30000 -- 30 seconds

-- Common ignore patterns for faster scanning
local ignore_patterns = {
  '^%.git/',
  '^%.svn/',
  '^%.hg/',
  'node_modules/',
  '%.pyc$',
  '%.o$',
  '%.obj$',
  '%.exe$',
  '%.dll$',
  '%.so$',
  '%.dylib$',
  '%.class$',
  '%.jar$',
  '%.war$',
  '%.ear$',
  'target/',
  'build/',
  'dist/',
  'out/',
  '%.tmp$',
  '%.temp$',
  '%.log$',
  '%.cache$',
}

local function should_ignore(path)
  for _, pattern in ipairs(ignore_patterns) do
    if path:match(pattern) then
      return true
    end
  end
  return false
end

local function find_files_fast(pattern, max_results)
  max_results = max_results or 500

  -- Try fd first (fastest and most reliable)
  if vim.fn.executable('fd') == 1 then
    local fd_pattern = pattern and pattern ~= '' and pattern or '.'
    local cmd = string.format('fd --type f --max-results %d "%s" 2>/dev/null', max_results, fd_pattern)
    local result = vim.fn.systemlist(cmd)
    if vim.v.shell_error == 0 then
      return result
    end
  end

  if vim.fn.executable('fdfind') == 1 then
    local fd_pattern = pattern and pattern ~= '' and pattern or '.'
    local cmd = string.format('fd --type f --max-results %d "%s" 2>/dev/null', max_results, fd_pattern)
    local result = vim.fn.systemlist(cmd)
    if vim.v.shell_error == 0 then
      return result
    end
  end

  -- Try rg as fallback
  if vim.fn.executable('rg') == 1 then
    local rg_pattern = pattern and pattern ~= '' and pattern or '.'
    local cmd = string.format('rg --files --glob "*%s*" 2>/dev/null | head -%d', rg_pattern, max_results)
    local result = vim.fn.systemlist(cmd)
    if vim.v.shell_error == 0 then
      return result
    end
  end

  -- Simple find fallback
  if vim.fn.executable('find') == 1 then
    local find_pattern = pattern and pattern ~= '' and string.format('-name "*%s*"', pattern) or '-type f'
    local cmd = string.format('find . -type f %s 2>/dev/null | head -%d', find_pattern, max_results)
    local result = vim.fn.systemlist(cmd)
    if vim.v.shell_error == 0 then
      for i, file in ipairs(result) do
        result[i] = file:gsub('^%./', '')
      end
      return result
    end
  end

  -- Minimal vim glob fallback slow but works everywhere
  local all_files = {}

  if pattern and pattern ~= '' then
    -- Just one simple deep search pattern
    local glob_pattern = '**/*' .. pattern .. '*'
    local vim_files = vim.fn.glob(glob_pattern, false, true)

    for _, file in ipairs(vim_files) do
      if vim.fn.isdirectory(file) == 0 and not should_ignore(file) then
        table.insert(all_files, file)
        if #all_files >= max_results then
          break
        end
      end
    end
  else
    -- For empty pattern, just current directory files
    local vim_files = vim.fn.glob('*', false, true)
    for _, file in ipairs(vim_files) do
      if vim.fn.isdirectory(file) == 0 and not should_ignore(file) then
        table.insert(all_files, file)
        if #all_files >= max_results then
          break
        end
      end
    end
  end

  return all_files
end

---@type CompletionSource
local file_source = {
  name = 'files',
  complete = function(context)
    local config = require('opencode.config').get()
    if context.trigger_char ~= config.keymap.window.mention then
      return {}
    end

    local input = context.input or ''
    local cache_key = input .. '_' .. vim.fn.getcwd()
    local current_time = vim.fn.reltime()

    if
      file_cache[cache_key]
      and vim.fn.reltimefloat(vim.fn.reltime(file_cache[cache_key].time)) < cache_timeout / 1000
    then
      return file_cache[cache_key].items
    end

    local items = {}

    if #input < 1 then
      local recent_files = {}
      for _, file in ipairs(vim.v.oldfiles) do
        if #recent_files >= 20 then
          break
        end
        local relative = vim.fn.fnamemodify(file, ':.')
        local is_in_cwd = vim.fn.getcwd() == vim.fn.fnamemodify(file, ':h')
        if is_in_cwd and (relative and relative ~= '' and not should_ignore(relative)) then
          table.insert(recent_files, relative)
        end
      end

      for _, file in ipairs(recent_files) do
        table.insert(items, {
          label = file,
          kind = 'file',
          detail = 'Recent file',
          documentation = 'Recently opened file: ' .. vim.fn.fnamemodify(file, ':p'),
          insert_text = file,
          source_name = 'files', -- Add source name
          data = { type = 'file', recent = true },
        })
      end

      file_cache[cache_key] = { items = items, time = current_time }
      if #items > 0 then
        return items
      end
    end

    local max_items = 50
    local files = find_files_fast(input, max_items)

    for _, file in ipairs(files) do
      if not should_ignore(file) then
        local path = vim.fn.fnamemodify(file, ':p')
        local filename = vim.fn.fnamemodify(file, ':t')
        local dir = vim.fn.fnamemodify(file, ':h')

        local item = {
          label = filename,
          kind = 'file',
          detail = (dir ~= '.' and dir or '.'),
          documentation = 'File path: ' .. vim.fn.fnamemodify(file, ':p'),
          insert_text = filename,
          source_name = 'files', -- Add source name
          data = {
            full_path = vim.fn.fnamemodify(file, ':p'),
            type = 'file',
          },
        }

        table.insert(items, item)
      end
    end

    -- Sort by relevance (exact matches first, then by path length)
    table.sort(items, function(a, b)
      local a_name = vim.fn.fnamemodify(a.label, ':t')
      local b_name = vim.fn.fnamemodify(b.label, ':t')
      local input_lower = input:lower()

      -- Exact filename matches come first
      local a_exact = a_name:lower() == input_lower
      local b_exact = b_name:lower() == input_lower
      if a_exact ~= b_exact then
        return a_exact
      end

      -- Then filename starts with input
      local a_starts = a_name:lower():find('^' .. vim.pesc(input_lower))
      local b_starts = b_name:lower():find('^' .. vim.pesc(input_lower))
      if a_starts ~= b_starts then
        return a_starts ~= nil
      end

      -- Then shorter paths
      return #a.label < #b.label
    end)

    -- Cache the results
    file_cache[cache_key] = { items = items, time = current_time }

    return items
  end,
  resolve = function(item)
    if item.data and item.data.full_path then
      local stat = vim.loop.fs_stat(item.data.full_path)
      if stat then
        item.documentation = string.format(
          '%s\n\nSize: %d bytes\nModified: %s',
          item.documentation or '',
          stat.size,
          os.date('%Y-%m-%d %H:%M:%S', stat.mtime.sec)
        )
      end
    end
    return item
  end,
  on_complete = function(item)
    -- Called when a file completion is selected
    vim.notify('File selected: ' .. item.label, vim.log.levels.INFO)

    -- You could add more functionality here, like:
    -- - Opening the file
    -- - Adding to recent files
    -- - Logging usage statistics
    if item.data and item.data.full_path then
      -- Maybe open the file in a split or tab
      -- vim.cmd('tabnew ' .. vim.fn.fnameescape(item.data.full_path))
    end
  end,
}

---Get the file completion source
---@return CompletionSource
function M.get_source()
  return file_source
end

return M
