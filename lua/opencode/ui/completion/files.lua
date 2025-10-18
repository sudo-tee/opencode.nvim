local config = require('opencode.config')
local M = {}

local last_successful_tool = nil

local function should_keep(ignore_patterns)
  return function(path)
    for _, pattern in ipairs(ignore_patterns) do
      if path:match(pattern) then
        return false
      end
    end
    return true
  end
end

local function run_systemlist(cmd)
  local ok, result = pcall(vim.fn.systemlist, cmd)
  return ok and vim.v.shell_error == 0 and result or nil
end

local function try_tool(tool, args, pattern, max, ignore_patterns)
  if type(args) == 'function' then
    local promise = args(pattern, max)
    local result = promise and promise.and_then and promise:wait()

    if result and type(result) == 'table' then
      return vim.tbl_filter(should_keep(ignore_patterns), result)
    end
  end

  if vim.fn.executable(tool) then
    pattern = vim.fn.shellescape(pattern) or '.'
    local result = run_systemlist(tool .. string.format(args, pattern, max))
    if result then
      return vim.tbl_filter(should_keep(ignore_patterns), result)
    end
  end
  return nil
end

---@param pattern string
---@return string[]
local function find_files_fast(pattern)
  local file_config = config.ui.completion.file_sources
  local cli_tool = last_successful_tool or file_config.preferred_cli_tool or 'server'
  local max = file_config.max_files or 10
  local ignore_patterns = file_config.ignore_patterns or {}

  local tools_order = { 'server', 'fd', 'fdfind', 'rg', 'git' }
  local commands = {
    fd = ' --type f --type l --full-path  --color=never -E .git -E node_modules -i %s --max-results %d 2>/dev/null',
    fdfind = ' --type f --type l --color=never -E .git -E node_modules --full-path -i %s --max-results %d 2>/dev/null',
    rg = ' --files --no-messages --color=never | grep -i %s 2>/dev/null | head -%d',
    git = ' ls-files --cached --others --exclude-standard | grep -i %s | head -%d',
    server = function(pattern)
      return require('opencode.state').api_client:find_files(pattern)
    end,
  }

  if cli_tool and commands[cli_tool] then
    tools_order = vim.tbl_filter(function(t)
      return t ~= cli_tool
    end, tools_order)
    table.insert(tools_order, 1, cli_tool)
  end

  for _, tool in ipairs(tools_order) do
    local result = try_tool(tool, commands[tool], pattern, max, ignore_patterns)
    if result then
      last_successful_tool = tool
      return result
    end
  end
  vim.notify('No suitable file search tool found. Please install fd, rg, or git.', vim.log.levels.WARN)
  return {}
end

---@param file string
---@return CompletionItem
local function create_file_item(file, suffix)
  local filename = vim.fn.fnamemodify(file, ':t')
  local dir = vim.fn.fnamemodify(file, ':h')
  local file_path = dir == '.' and filename or dir .. '/' .. filename
  local detail = dir == '.' and filename or dir .. '/' .. filename
  local full_path = vim.fn.fnamemodify(file, ':p')
  local display_label = file_path

  local file_config = config.ui.completion.file_sources
  local max_display_len = file_config.max_display_length or 50
  if #display_label > max_display_len then
    display_label = '...' .. display_label:sub(-(max_display_len - 3))
  end

  return {
    label = display_label .. (suffix or ''),
    kind = 'file',
    detail = detail,
    documentation = 'Path: ' .. detail,
    insert_text = file_path,
    source_name = 'files',
    data = { name = filename, full_path = full_path },
  }
end

---@type CompletionSource
local file_source = {
  name = 'files',
  priority = 5,
  complete = function(context)
    local sort_util = require('opencode.ui.completion.sort')
    local file_config = config.ui.completion.file_sources
    local input = context.input or ''

    local config_mod = require('opencode.config')
    local expected_trigger = config_mod.get_key_for_function('input_window', 'mention')
    if not file_config.enabled or context.trigger_char ~= expected_trigger then
      return {}
    end

    local recent_files = #input < 1 and M.get_recent_files() or {}
    if #recent_files >= 5 then
      return recent_files
    end

    local files_and_dirs = find_files_fast(input)
    local items = vim.tbl_map(create_file_item, files_and_dirs)
    sort_util.sort_by_relevance(items, input, function(item)
      return vim.fn.fnamemodify(item.label, ':t')
    end, function(a, b)
      return #a.label < #b.label
    end)

    return vim.list_extend(recent_files, items)
  end,
  on_complete = function(item)
    local state = require('opencode.state')
    local context = require('opencode.context')
    local mention = require('opencode.ui.mention')
    mention.highlight_all_mentions(state.windows.input_buf)

    context.add_file(item.data.full_path)
  end,
}

---Get the list of recent files
---@return CompletionItem[]
function M.get_recent_files()
  local api_client = require('opencode.state').api_client

  local result = api_client:get_file_status():wait()
  local recent_files = {}
  if result then
    for _, file in ipairs(result) do
      local suffix = table.concat({ file.added and '+' .. file.added, file.removed and '-' .. file.removed }, ' ')
      table.insert(recent_files, create_file_item(file.path, ' ' .. suffix))
    end
  end
  return recent_files
end

---Get the list of old files in the current working directory
---@return string[]
function M.get_old_files()
  local result = {}
  for _, file in ipairs(vim.v.oldfiles) do
    if vim.startswith(vim.fn.fnamemodify(file, ':p'), vim.fn.getcwd()) then
      table.insert(result, vim.fn.fnamemodify(file, ':.'))
    end
  end
  return result
end

---Get the list of changed files in git (staged, unstaged, untracked)
---@return string[]|nil
function M.get_git_changed_files()
  local results = run_systemlist('git status --porcelain')

  local files = {}
  for _, line in ipairs(results or {}) do
    local file = line:sub(4)
    if file and file ~= '' and vim.trim(line:sub(1, 2)) ~= 'D' then
      table.insert(files, file)
    end
  end

  return #files > 0 and files or nil
end

---Get the file completion source
---@return CompletionSource
function M.get_source()
  return file_source
end

return M
