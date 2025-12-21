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

---Extract surrounding context for display
---@param text string Full text
---@param match_start number Start position of match
---@param match_end number End position of match
---@param max_len number Maximum context length
---@return string
local function extract_context(text, match_start, match_end, max_len)
  max_len = max_len or 60
  local half = math.floor(max_len / 2)

  -- Find line boundaries for better context
  local line_start = match_start
  local line_end = match_end

  -- Go back to find start of line or limit
  while line_start > 1 and text:sub(line_start - 1, line_start - 1) ~= '\n' and (match_start - line_start) < half do
    line_start = line_start - 1
  end

  -- Go forward to find end of line or limit
  while line_end < #text and text:sub(line_end + 1, line_end + 1) ~= '\n' and (line_end - match_end) < half do
    line_end = line_end + 1
  end

  local context = text:sub(line_start, line_end)

  -- Clean up: remove extra whitespace
  context = context:gsub('%s+', ' ')
  context = vim.trim(context)

  -- Truncate if still too long
  if #context > max_len then
    -- Try to center around the match
    local match_in_context = match_start - line_start + 1
    local ctx_start = math.max(1, match_in_context - half)
    local ctx_end = math.min(#context, match_in_context + half)
    context = context:sub(ctx_start, ctx_end)

    if ctx_start > 1 then
      context = '...' .. context
    end
    if ctx_end < #context then
      context = context .. '...'
    end
  end

  return context
end

---@class CodeReference
---@field file_path string Relative or absolute file path
---@field line number|nil Line number (1-indexed)
---@field column number|nil Column number (optional)
---@field context string Surrounding text for display
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
  local seen = {} -- For deduplication: file_path:line

  -- Pattern: path/to/file.ext:line or path/to/file.ext:line:column
  -- Must have a valid file extension before the colon
  -- The path can contain: alphanumeric, underscore, dot, slash, hyphen
  local pattern = '([%w_./%-]+%.([%w]+)):(%d+):?(%d*)'

  local search_start = 1
  while search_start <= #text do
    local match_start, match_end, path, ext, line_str, col_str = text:find(pattern, search_start)

    if not match_start then
      break
    end

    -- Validate extension
    if is_valid_extension(ext) and not is_url_context(text, match_start) then
      -- Check if file exists
      if file_exists(path) then
        local line = tonumber(line_str)
        local column = col_str ~= '' and tonumber(col_str) or nil

        -- Deduplication key
        local dedup_key = path .. ':' .. (line or 0)
        if not seen[dedup_key] then
          seen[dedup_key] = true

          local context = extract_context(text, match_start, match_end --[[@as number]], 60)

          -- Create absolute path for Snacks preview
          local abs_path = path
          if not vim.startswith(path, '/') then
            abs_path = vim.fn.getcwd() .. '/' .. path
          end

          table.insert(references, {
            file_path = path,
            line = line,
            column = column,
            context = context,
            message_id = message_id,
            match_start = match_start,
            match_end = match_end,
            -- Fields for Snacks picker file preview
            file = abs_path,
            pos = line and { line, (column or 1) - 1 } or nil,
          })
        end
      end
    end

    search_start = match_end + 1
  end

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
  local location = ref.file_path .. ':' .. (ref.line or '?')
  local display_text = icon .. ' ' .. location

  -- Create picker item with context as secondary info
  -- We'll use the debug_text field to show the context
  return base_picker.create_picker_item(display_text, nil, ref.context, width)
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
