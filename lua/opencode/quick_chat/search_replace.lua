local M = {}

local PATTERNS = {
  search_start = '<<<<<<<[<]*%s*SEARCH%s*\n',
  separator = '=======%s*\n',
  replace_end = '\n?>>>>>>>[>]*%s*REPLACE[^\n]*',
  code_fence = '```[^\n]*\n(.-)```',

  whitespace = '%s+',
  trim_left = '^%s+',
  trim_right = '%s+$',
}

local MAGIC_CHARS = '[%(%)%.%+%-%*%?%[%]%^%$%%]'

--- Normalize whitespace in text by collapsing multiple spaces and trimming.
--- @param text string The text to normalize
--- @return string The normalized text
local function normalize_whitespace(text)
  return text:gsub(PATTERNS.whitespace, ' '):gsub(PATTERNS.trim_left, ''):gsub(PATTERNS.trim_right, '')
end

--- Escape magic characters in a string for use in Lua patterns.
--- @param text string The text to escape
--- @return string The escaped text
local function escape_pattern(text)
  return text:gsub(MAGIC_CHARS, '%%%1')
end

--- Safely find a pattern in text, handling potential errors.
--- @param text string The text to search in
--- @param pattern string The pattern to search for
--- @return number|nil start Start position of match
--- @return number|nil _end End position of match
local function safe_find(text, pattern)
  local ok, start, _end = pcall(text.find, text, pattern)
  if ok then
    return start, _end
  end
end

--- Strip patch block markers from text and return the content.
--- @param text string The text containing patch markers
--- @return string The content with markers stripped
local function strip_markers(text)
  local start = text:find(PATTERNS.search_start)
  local sep = text:find(PATTERNS.separator)
  local _end = text:find(PATTERNS.replace_end)

  if not (start and sep and _end) then
    return text
  end

  local content_start = text:find('\n', start) + 1
  -- Find the position right before the separator, handling the case where 
  -- the separator doesn't require a preceding newline
  local content_end = sep - 1
  if text:sub(content_end, content_end) == '\n' then
    content_end = content_end - 1
  end
  
  return text:sub(content_start, content_end)
end

--- Find a substring in content, ignoring flexible whitespace.
--- @param content string
--- @param search string
--- @return number|nil s Start index of match
--- @return number|nil e End index of match
--- @return boolean|nil exact True if exact match, nil otherwise
local function find_with_flexible_whitespace(content, search)
  -- Exact match first
  local start, _end = content:find(search, 1, true)
  if start then
    return start, _end, true
  end

  local normalized = normalize_whitespace(search)
  if normalized == '' then
    return
  end

  -- Flexible whitespace pattern
  local escaped = escape_pattern(normalized)
  local flexible = escaped:gsub(' ', '%%s+')

  start, _end = safe_find(content, flexible)
  if start then
    return start, _end, false
  end

  -- Word-based fallback
  local words = {}
  for w in normalized:gmatch('%S+') do
    words[#words + 1] = escape_pattern(w)
  end

  if #words > 1 then
    local pattern = table.concat(words, '%%s+')
    start, _end = safe_find(content, pattern)
    if start then
      return start, _end, false
    end
  end
end

--- Find the next patch block in the text after the given position.
---@param text string The text to search in
---@param pos number The position to start searching from
---@return table|nil block The block data, or nil if not found
---@return string|nil error_msg Error message if block is malformed
local function next_block(text, pos)
  local start, _end = text:find(PATTERNS.search_start, pos)
  if not start then
    return
  end

  local sep_start, sep_end = text:find(PATTERNS.separator, _end + 1)
  if not sep_start then
    return nil, 'Missing separator (=======)'
  end

  local end_s, end_e = text:find(PATTERNS.replace_end, sep_end + 1)
  if not end_s then
    return nil, 'Missing end marker (>>>>>>> REPLACE)'
  end

  -- Find the last newline before the separator to get the exact search content
  local search_content_start = _end + 1
  local search_content_end = sep_start - 1
  
  -- Check if there's a newline right before the separator
  if text:sub(search_content_end, search_content_end) == '\n' then
    search_content_end = search_content_end - 1
  end
  
  local search_content = text:sub(search_content_start, search_content_end)

  return {
    search = search_content,
    replace = text:sub(sep_end + 1, end_s - 1),
    next_pos = end_e + 1,
  }
end

---@param response_text string
---@return table replacements, table warnings
function M.parse_blocks(response_text)
  local text = response_text:gsub('\r\n', '\n'):gsub(PATTERNS.code_fence, '%1')

  local replacements = {}
  local warnings = {}

  local pos = 1
  local block_number = 0

  while pos <= #text do
    local result, err = next_block(text, pos)

    -- Check if we found a search start pattern
    local search_start = text:find(PATTERNS.search_start, pos)
    if not search_start then
      break
    end

    block_number = block_number + 1

    if err then
      warnings[#warnings + 1] = string.format('Block %d: %s', block_number, err)
      -- For malformed blocks, advance to next search start + 1 to continue
      pos = search_start + 1
    elseif result then
      local is_insert = result.search:match('^%s*$') ~= nil

      replacements[#replacements + 1] = {
        search = is_insert and '' or result.search,
        replace = result.replace,
        block_number = block_number,
        is_insert = is_insert,
      }

      pos = result.next_pos
    else
      break
    end
  end

  return replacements, warnings
end

---@param buf number
---@param row number
---@param text string
local function apply_insert(buf, row, text)
  local lines = vim.split(text, '\n', { plain = true })
  vim.api.nvim_buf_set_lines(buf, row, row, false, lines)
end

---@param content string
---@param search string
---@param replace string
---@return string|nil, integer|nil, integer|nil
local function apply_replace(content, search, replace)
  local cleaned = strip_markers(search)
  local start, _end = find_with_flexible_whitespace(content, cleaned)
  if not start then
    return
  end
  return content:sub(1, start - 1) .. replace .. content:sub(_end + 1)
end

---Apply replacements to the buffer content.
---@param buf integer
---@param replacements table
---@param cursor_row integer
---@return boolean, table, integer
function M.apply(buf, replacements, cursor_row)
  if not vim.api.nvim_buf_is_valid(buf) then
    return false, { 'Buffer is not valid' }, 0
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local content = table.concat(lines, '\n')

  local applied = 0
  local errors = {}

  for _, r in ipairs(replacements) do
    if r.is_insert then
      if cursor_row == nil then
        errors[#errors + 1] = 'Insert operation requires cursor position'
      else
        apply_insert(buf, cursor_row, r.replace)
        applied = applied + 1

        lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        content = table.concat(lines, '\n')
      end
    else
      local new_content = apply_replace(content, r.search, r.replace)
      if new_content then
        content = new_content
        applied = applied + 1
      else
        local preview = r.search:sub(1, 60):gsub('\n', '\\n')
        if #r.search > 60 then
          preview = preview .. '...'
        end
        errors[#errors + 1] = 'No match (exact or flexible)'
      end
    end
  end

  if applied > 0 then
    local new_lines = vim.split(content, '\n', { plain = true })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
  end

  return applied > 0, errors, applied
end

return M
