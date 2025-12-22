-- Code reference picker for navigating to file:line references in LLM responses
local state = require('opencode.state')
local config = require('opencode.config')
local base_picker = require('opencode.ui.base_picker')
local icons = require('opencode.ui.icons')

local M = {}

-- File extensions to recognize as valid code files
local VALID_EXTENSIONS = {
  'lua',
  'py',
  'js',
  'ts',
  'tsx',
  'jsx',
  'go',
  'rs',
  'c',
  'cpp',
  'h',
  'hpp',
  'java',
  'rb',
  'php',
  'swift',
  'kt',
  'scala',
  'sh',
  'bash',
  'zsh',
  'json',
  'yaml',
  'yml',
  'toml',
  'xml',
  'html',
  'css',
  'scss',
  'md',
  'txt',
  'vim',
  'el',
  'ex',
  'exs',
  'erl',
  'hs',
  'ml',
  'fs',
  'clj',
  'r',
  'sql',
  'graphql',
  'proto',
  'tf',
  'nix',
  'zig',
  'v',
  'svelte',
  'vue',
}

-- Build a lookup set for faster extension checking
local EXTENSION_SET = {}
for _, ext in ipairs(VALID_EXTENSIONS) do
  EXTENSION_SET[ext] = true
end

---Check if a file extension is valid
---@param ext string
---@return boolean
local function is_valid_extension(ext)
  return EXTENSION_SET[ext:lower()] == true
end

---Check if the path looks like a URL (to avoid false positives)
---@param text string
---@param match_start number
---@return boolean
local function is_url_context(text, match_start)
  -- Check if preceded by :// (like http://, file://, etc.)
  if match_start > 3 then
    local prefix = text:sub(match_start - 3, match_start - 1)
    if prefix:match('://$') then
      return true
    end
  end
  return false
end

---Check if a file exists
---@param file_path string
---@return boolean
local function file_exists(file_path)
  local path = file_path
  -- Make absolute if relative
  if not vim.startswith(path, '/') then
    path = vim.fn.getcwd() .. '/' .. path
  end
  return vim.fn.filereadable(path) == 1
end

---@class CodeReference
---@field file_path string Relative or absolute file path
---@field line number|nil Line number (1-indexed)
---@field column number|nil Column number (optional)
---@field message_id string ID of the message containing this reference
---@field match_start number Start position in original text
---@field match_end number End position in original text
---@field file string Absolute file path (for Snacks picker preview)
---@field pos number[]|nil Position as {line, col} for Snacks picker preview

---Parse references from text
---@param text string The text to parse
---@param message_id string The message ID for tracking
---@return CodeReference[]
function M.parse_references(text, message_id)
  local references = {}
  local covered_ranges = {} -- Track which character ranges we've already matched

  -- Helper to check if a range overlaps with any covered range
  local function is_covered(start_pos, end_pos)
    for _, range in ipairs(covered_ranges) do
      -- Check if ranges overlap
      if not (end_pos < range[1] or start_pos > range[2]) then
        return true
      end
    end
    return false
  end

  -- Helper to add a reference
  local function add_reference(path, ext, match_start, match_end, line, column)
    if not is_valid_extension(ext) then
      return false
    end
    if not file_exists(path) then
      return false
    end
    if is_covered(match_start, match_end) then
      return false
    end

    -- Mark this range as covered
    table.insert(covered_ranges, { match_start, match_end })

    -- Create absolute path for Snacks preview
    local abs_path = path
    if not vim.startswith(path, '/') then
      abs_path = vim.fn.getcwd() .. '/' .. path
    end

    table.insert(references, {
      file_path = path,
      line = line,
      column = column,
      message_id = message_id,
      match_start = match_start,
      match_end = match_end,
      file = abs_path,
      pos = line and { line, (column or 1) - 1 } or nil,
    })
    return true
  end

  -- First pass: find file:// URI references (preferred format)
  -- Matches: file://path/to/file.ext or file://path/to/file.ext:line or file://path/to/file.ext:line:column
  local pattern_file_uri = 'file://([%w_./%-]+%.([%w]+)):?(%d*):?(%d*)'
  local search_start = 1
  while search_start <= #text do
    local match_start, match_end, path, ext, line_str, col_str = text:find(pattern_file_uri, search_start)
    if not match_start then
      break
    end

    local line = line_str ~= '' and tonumber(line_str) or nil
    local column = col_str ~= '' and tonumber(col_str) or nil
    add_reference(path, ext, match_start, match_end, line, column)
    search_start = match_end + 1
  end

  -- Second pass: find path:line[:column] references (legacy format, more specific)
  local pattern_with_line = '([%w_./%-]+%.([%w]+)):(%d+):?(%d*)'
  search_start = 1
  while search_start <= #text do
    local match_start, match_end, path, ext, line_str, col_str = text:find(pattern_with_line, search_start)
    if not match_start then
      break
    end

    -- Skip if this looks like a URL (http://, https://, file://, etc.)
    if is_url_context(text, match_start) then
      search_start = match_end + 1
    else
      local line = tonumber(line_str)
      local column = col_str ~= '' and tonumber(col_str) or nil
      add_reference(path, ext, match_start, match_end, line, column)
      search_start = match_end + 1
    end
  end

  -- Third pass: find path-only references (must contain a slash to be a path)
  local pattern_no_line = '([%w_%-]+/[%w_./%-]+%.([%w]+))'
  search_start = 1
  while search_start <= #text do
    local match_start, match_end, path, ext = text:find(pattern_no_line, search_start)
    if not match_start then
      break
    end

    -- Skip if preceded by file:// or other URL scheme
    if is_url_context(text, match_start) then
      search_start = match_end + 1
    -- Only add if not followed by a colon and digit (which would be caught by second pattern)
    elseif text:sub(match_end + 1, match_end + 1) ~= ':' then
      add_reference(path, ext, match_start, match_end, nil, nil)
      search_start = match_end + 1
    else
      search_start = match_end + 1
    end
  end

  -- Sort by match position for consistent ordering
  table.sort(references, function(a, b)
    return a.match_start < b.match_start
  end)

  return references
end

---Collect all references from assistant messages in the current session
---Returns references in reverse order (most recent first)
---@return CodeReference[]
function M.collect_references()
  local all_references = {}

  if not state.messages then
    return all_references
  end

  -- Process messages in reverse order (most recent first)
  for i = #state.messages, 1, -1 do
    local msg = state.messages[i]

    -- Only process assistant messages
    if msg.info and msg.info.role == 'assistant' and msg.parts then
      for _, part in ipairs(msg.parts) do
        -- Only process text parts (not tool calls)
        if part.type == 'text' and part.text then
          local refs = M.parse_references(part.text, msg.info.id)
          for _, ref in ipairs(refs) do
            table.insert(all_references, ref)
          end
        end
      end
    end
  end

  -- Deduplicate across all messages (keep first occurrence which is most recent)
  local seen = {}
  local deduplicated = {}
  for _, ref in ipairs(all_references) do
    local dedup_key = ref.file_path .. ':' .. (ref.line or 0)
    if not seen[dedup_key] then
      seen[dedup_key] = true
      table.insert(deduplicated, ref)
    end
  end

  return deduplicated
end

---Get references for a specific text (used by formatter for visual indicators)
---@param text string
---@return CodeReference[]
function M.get_references_for_text(text)
  return M.parse_references(text, '')
end

---Format a reference for display in the picker
---@param ref CodeReference
---@param width number|nil
---@return PickerItem
local function format_reference_item(ref, width)
  local icon = icons.get('file')
  local location = ref.line and (ref.file_path .. ':' .. ref.line) or ref.file_path
  local display_text = icon .. ' ' .. location

  return base_picker.create_picker_item(display_text, nil, nil, width)
end

---Open the reference picker
function M.pick()
  local references = M.collect_references()

  if #references == 0 then
    vim.notify('No code references found in the conversation', vim.log.levels.INFO)
    return
  end

  local callback = function(selected)
    if selected then
      M.navigate_to(selected)
    end
  end

  return base_picker.pick({
    items = references,
    format_fn = format_reference_item,
    actions = {},
    callback = callback,
    title = 'Code References (' .. #references .. ')',
    width = config.ui.picker_width or 100,
    preview = 'file',
  })
end

---Navigate to a code reference
---@param ref CodeReference
function M.navigate_to(ref)
  local file_path = ref.file_path

  -- Make absolute if relative
  if not vim.startswith(file_path, '/') then
    file_path = vim.fn.getcwd() .. '/' .. file_path
  end

  -- Open the file in a new tab
  vim.cmd('tabedit ' .. vim.fn.fnameescape(file_path))

  -- Jump to line if specified
  if ref.line then
    local line = math.max(1, ref.line)
    local col = ref.column and math.max(0, ref.column - 1) or 0

    -- Make sure we don't exceed buffer line count
    local line_count = vim.api.nvim_buf_line_count(0)
    line = math.min(line, line_count)

    vim.api.nvim_win_set_cursor(0, { line, col })
    vim.cmd('normal! zz') -- Center the view
  end
end

return M
