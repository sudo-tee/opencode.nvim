local M = {}

--- Parses SEARCH/REPLACE blocks from response text
--- Supports both raw and code-fenced formats:
---   <<<<<<< SEARCH ... ======= ... >>>>>>> REPLACE
---   ```\n<<<<<<< SEARCH ... ======= ... >>>>>>> REPLACE\n```
--- Empty SEARCH sections are valid and indicate "insert at cursor position"
---@param response_text string Response text containing SEARCH/REPLACE blocks
---@return table[] replacements Array of {search=string, replace=string, block_number=number, is_insert=boolean}
---@return string[] warnings Array of warning messages for malformed blocks
function M.parse_blocks(response_text)
  local replacements = {}
  local warnings = {}

  -- Normalize line endings
  local text = response_text:gsub('\r\n', '\n')

  -- Remove code fences if present (```...```)
  text = text:gsub('```[^\n]*\n(.-)```', '%1')

  local block_number = 0
  local pos = 1

  while pos <= #text do
    -- Find the start marker (require at least 7 < characters)
    local search_start, search_end = text:find('<<<<<<<[<]*[ \t]*SEARCH[ \t]*\n', pos)
    if not search_start or not search_end then
      break
    end

    block_number = block_number + 1
    local content_start = search_end + 1

    -- Find the separator (require exactly 7 = characters)
    local separator_start, separator_end = text:find('\n=======%s*\n', content_start)
    if not separator_start then
      table.insert(warnings, string.format('Block %d: Missing separator (=======)', block_number))
      pos = search_start + 1
    else
      local search_content = text:sub(content_start, separator_start - 1)

      -- Find the end marker (require at least 7 > characters, newline optional for empty replace)
      local replace_start = separator_end + 1
      local end_marker_start, end_marker_end = text:find('\n?>>>>>>>[>]*%s*REPLACE[^\n]*', replace_start)
      if not end_marker_start then
        table.insert(warnings, string.format('Block %d: Missing end marker (>>>>>>> REPLACE)', block_number))
        pos = search_start + 1
      else
        -- Extract replace content (everything between separator and end marker)
        local replace_content = text:sub(replace_start, end_marker_start - 1)

        local is_insert = search_content:match('^%s*$') ~= nil
        table.insert(replacements, {
          search = is_insert and '' or search_content,
          replace = replace_content,
          block_number = block_number,
          is_insert = is_insert,
        })
        pos = end_marker_end + 1
      end
    end
  end

  return replacements, warnings
end

--- Applies SEARCH/REPLACE blocks to buffer content using exact matching
--- Empty SEARCH sections (is_insert=true) will insert at the specified cursor row
---@param buf integer Buffer handle
---@param replacements table[] Array of {search=string, replace=string, block_number=number, is_insert=boolean}
---@param cursor_row? integer Optional cursor row (0-indexed) for insert operations
---@return boolean success Whether any replacements were applied
---@return string[] errors List of error messages for failed replacements
---@return number applied_count Number of successfully applied replacements
function M.apply(buf, replacements, cursor_row)
  if not vim.api.nvim_buf_is_valid(buf) then
    return false, { 'Buffer is not valid' }, 0
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local content = table.concat(lines, '\n')

  local applied_count = 0
  local errors = {}

  for _, replacement in ipairs(replacements) do
    local search = replacement.search
    local replace = replacement.replace
    local block_num = replacement.block_number or '?'
    local is_insert = replacement.is_insert

    if is_insert then
      -- Empty SEARCH: insert at cursor row
      if not cursor_row then
        table.insert(errors, string.format('Block %d: Insert operation requires cursor position', block_num))
      else
        -- Split replace content into lines and insert at cursor row
        local replace_lines = vim.split(replace, '\n', { plain = true })
        vim.api.nvim_buf_set_lines(buf, cursor_row, cursor_row, false, replace_lines)
        applied_count = applied_count + 1
        -- Refresh lines and content after direct buffer modification
        lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        content = table.concat(lines, '\n')
      end
    else
      -- Exact match only
      local start_pos, end_pos = content:find(search, 1, true)

      if start_pos and end_pos then
        content = content:sub(1, start_pos - 1) .. replace .. content:sub(end_pos + 1)
        applied_count = applied_count + 1
      else
        local search_preview = search:sub(1, 60):gsub('\n', '\\n')
        if #search > 60 then
          search_preview = search_preview .. '...'
        end
        table.insert(errors, string.format('Block %d: No exact match for: "%s"', block_num, search_preview))
      end
    end
  end

  -- Apply remaining content changes (for non-insert replacements)
  if applied_count > 0 then
    local new_lines = vim.split(content, '\n', { plain = true })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
  end

  return applied_count > 0, errors, applied_count
end

return M
