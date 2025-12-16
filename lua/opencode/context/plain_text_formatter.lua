-- Plain text formatter for context
-- Outputs human-readable plain text for LLM consumption (used by quick chat)

local util = require('opencode.util')
local Promise = require('opencode.promise')

local M = {}

local severity_names = {
  [1] = 'ERROR',
  [2] = 'WARNING',
  [3] = 'INFO',
  [4] = 'HINT',
}

---@param selection OpencodeContextSelection
---@return string
function M.format_selection(selection)
  local lang = util.get_markdown_filetype(selection.file and selection.file.name or '') or ''
  local file_info = selection.file and selection.file.name or 'unknown'
  local lines_info = selection.lines and (' (lines ' .. selection.lines .. ')') or ''

  local parts = {
    'SELECTED CODE from ' .. file_info .. lines_info .. ':',
    '```' .. lang,
    selection.content,
    '```',
  }
  return table.concat(parts, '\n')
end

---@param diagnostics OpencodeDiagnostic[]
---@param range? { start_line: integer, end_line: integer }|nil
---@return string|nil
function M.format_diagnostics(diagnostics, range)
  if not diagnostics or #diagnostics == 0 then
    return nil
  end

  local filtered = {}
  for _, diag in ipairs(diagnostics) do
    local in_range = not range or (diag.lnum >= range.start_line and diag.lnum <= range.end_line)
    if in_range then
      local severity = severity_names[diag.severity] or 'UNKNOWN'
      local line_num = diag.lnum + 1
      local col_num = diag.col + 1
      local msg = diag.message:gsub('%s+', ' '):gsub('^%s', ''):gsub('%s$', '')
      table.insert(filtered, string.format('  Line %d, Col %d [%s]: %s', line_num, col_num, severity, msg))
    end
  end

  if #filtered == 0 then
    return nil
  end

  return 'DIAGNOSTICS:\n' .. table.concat(filtered, '\n')
end

---@param cursor_data table
---@param lang string|nil
---@return string
function M.format_cursor_data(cursor_data, lang)
  lang = lang or ''
  local parts = {
    string.format('CURSOR POSITION: Line %d, Column %d', cursor_data.line, cursor_data.column),
  }

  if cursor_data.lines_before and #cursor_data.lines_before > 0 then
    table.insert(parts, 'Lines before cursor:')
    table.insert(parts, '```' .. lang)
    table.insert(parts, table.concat(cursor_data.lines_before, '\n'))
    table.insert(parts, '```')
  end

  table.insert(parts, 'Current line:')
  table.insert(parts, '```' .. lang)
  table.insert(parts, cursor_data.line_content)
  table.insert(parts, '```')

  if cursor_data.lines_after and #cursor_data.lines_after > 0 then
    table.insert(parts, 'Lines after cursor:')
    table.insert(parts, '```' .. lang)
    table.insert(parts, table.concat(cursor_data.lines_after, '\n'))
    table.insert(parts, '```')
  end

  return table.concat(parts, '\n')
end

---@param diff_text string
---@return string
function M.format_git_diff(diff_text)
  return 'GIT DIFF (staged changes):\n```diff\n' .. diff_text .. '\n```'
end

---@param buf integer
---@param lang string|nil
---@return string
function M.format_buffer(buf, lang)
  lang = lang or ''
  local file = vim.api.nvim_buf_get_name(buf)
  local rel_path = vim.fn.fnamemodify(file, ':~:.')
  local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')

  return string.format('FILE: %s\n\n```%s\n%s\n```', rel_path, lang, content)
end

--- Formats context as plain text for LLM consumption (used by quick chat)
--- Unlike format_message_quick_chat, this outputs human-readable text instead of JSON
---@param prompt string The user's instruction/prompt
---@param context_instance ContextInstance Context instance to use
---@param opts? { range?: { start: integer, stop: integer }, buf?: integer }
---@return table result { text: string, parts: OpencodeMessagePart[] }
M.format_message = Promise.async(function(prompt, context_instance, opts)
  opts = opts or {}
  local buf = opts.buf or context_instance:get_current_buf() or vim.api.nvim_get_current_buf()
  local range = opts.range

  local file_name = vim.api.nvim_buf_get_name(buf)
  local lang = util.get_markdown_filetype(file_name) or vim.fn.fnamemodify(file_name, ':e') or ''
  local rel_path = file_name ~= '' and vim.fn.fnamemodify(file_name, ':~:.') or 'untitled'

  local text_parts = {}

  -- Add file/buffer content
  if context_instance:is_context_enabled('buffer') then
    if range and range.start and range.stop then
      local start_line = math.max(1, range.start)
      local end_line = range.stop
      local range_lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)
      local range_text = table.concat(range_lines, '\n')

      table.insert(text_parts, string.format('FILE: %s (lines %d-%d)', rel_path, start_line, end_line))
      table.insert(text_parts, '')
      table.insert(text_parts, '```' .. lang)
      table.insert(text_parts, range_text)
      table.insert(text_parts, '```')
    else
      table.insert(text_parts, M.format_buffer(buf, lang))
    end
  end

  for _, sel in ipairs(context_instance:get_selections() or {}) do
    table.insert(text_parts, '')
    table.insert(text_parts, M.format_selection(sel))
  end

  local diagnostics = context_instance:get_diagnostics(buf)
  if diagnostics and #diagnostics > 0 then
    local diag_range = nil
    if range then
      diag_range = { start_line = range.start - 1, end_line = range.stop - 1 }
    end
    local formatted_diag = M.format_diagnostics(diagnostics, diag_range)
    if formatted_diag then
      table.insert(text_parts, '')
      table.insert(text_parts, formatted_diag)
    end
  end

  if context_instance:is_context_enabled('cursor_data') then
    local current_buf, current_win = context_instance:get_current_buf()
    local cursor_data = context_instance:get_current_cursor_data(current_buf or buf, current_win or 0)
    if cursor_data then
      table.insert(text_parts, '')
      table.insert(text_parts, M.format_cursor_data(cursor_data, lang))
    end
  end

  if context_instance:is_context_enabled('git_diff') then
    local diff_text = context_instance:get_git_diff():await()
    if diff_text and diff_text ~= '' then
      table.insert(text_parts, '')
      table.insert(text_parts, M.format_git_diff(diff_text))
    end
  end

  table.insert(text_parts, '')
  table.insert(text_parts, 'USER PROMPT: ' .. prompt)

  local full_text = table.concat(text_parts, '\n')

  return {
    text = full_text,
    parts = { { type = 'text', text = full_text } },
  }
end)

return M
