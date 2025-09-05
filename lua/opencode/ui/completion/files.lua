local config = require('opencode.config').get()
local M = {}

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

---@param pattern string
---@return string[]
local function find_files_fast(pattern)
  pattern = vim.fn.shellescape(pattern) or '.'
  local file_config = config.ui.completion.file_sources
  local cli_tool = file_config.preferred_cli_tool or 'fd'
  local max = file_config.max_files or 10

  local commands = {
    fd = string.format(' --type f --max-results %d %s 2>/dev/null', max, pattern),
    fdfind = string.format(' --type f --max-results %d %s 2>/dev/null', max, pattern),
    rg = string.format(' --files --glob %s 2>/dev/null | head -%d', ('*' .. pattern .. '*'), max),
    git = string.format(' ls-files --cached --others --exclude-standard | grep %s | head -%d', pattern, max),
    find = string.format(
      ' . -type f -name %s 2>/dev/null | sed "s|^\\./||"',
      '*' .. (pattern ~= '.' and pattern or '') .. '*'
    ),
  }

  local tools_to_try = commands[cli_tool] and { [cli_tool] = commands[cli_tool] } or commands

  for tool, args in pairs(tools_to_try) do
    if vim.fn.executable(tool) then
      local result = run_systemlist(tool .. args)
      if result then
        return vim.tbl_filter(should_keep(file_config.ignore_patterns or {}), result)
      end
    end
  end
  return {}
end

---@param file string
---@return CompletionItem
local function create_file_item(file)
  local filename = vim.fn.fnamemodify(file, ':t')
  local dir = vim.fn.fnamemodify(file, ':h')
  local display_path = dir == '.' and filename or dir .. '/' .. filename
  local detail = dir == '.' and filename or dir .. '/' .. filename

  return {
    label = display_path,
    kind = 'file',
    detail = detail,
    documentation = 'Path: ' .. detail,
    insert_text = filename,
    source_name = 'files',
    data = { name = filename, full_path = vim.fn.fnamemodify(file, ':p') },
  }
end

---@type CompletionSource
local file_source = {
  name = 'files',
  priority = 0,
  complete = function(context)
    local sort_util = require('opencode.ui.completion.sort')
    local file_config = config.ui.completion.file_sources
    local input = context.input or ''

    if not file_config.enabled or context.trigger_char ~= config.keymap.window.mention then
      return {}
    end

    local recent_files = #input < 1 and M.get_recent_files() or {}
    if #recent_files >= 5 then
      return recent_files
    end

    local items = vim.tbl_map(create_file_item, find_files_fast(input))
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
  local project = require('opencode.config_file').get_opencode_project()
  local max = config.ui.completion.file_sources.max_files
  local is_git = project and project.vcs == 'git'

  local recent_files = is_git and M.get_git_changed_files() or M.get_old_files() or {}
  return vim.tbl_map(create_file_item, { unpack(recent_files, 1, max) })
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
