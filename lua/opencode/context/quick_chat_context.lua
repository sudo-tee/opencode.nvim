local base_context = require('opencode.context.base_context')
local util = require('opencode.util')
local Promise = require('opencode.promise')

local M = {}

local severity_names = {
  [1] = 'ERROR',
  [2] = 'WARNING',
  [3] = 'INFO',
  [4] = 'HINT',
}

---@param selection table
---@return string
local function format_selection(selection)
  local lang = util.get_markdown_filetype(selection.file and selection.file.name or '') or ''
  local file_info = selection.file and selection.file.name or 'unknown'
  local lines_info = selection.lines and (' (lines ' .. selection.lines .. ')') or ''

  local parts = {
    '[SELECTED CODE] from ' .. file_info .. lines_info .. ':',
    '```' .. lang,
    selection.content,
    '```',
  }
  return table.concat(parts, '\n')
end

---@param diagnostics OpencodeDiagnostic[]
---@param range? { start_line: integer, end_line: integer }|nil
---@return string|nil
local function format_diagnostics(diagnostics, range)
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

  return '[DIAGNOSTICS]:\n' .. table.concat(filtered, '\n')
end

---@param cursor_data table
---@param lang string|nil
---@return string
local function format_cursor_data(cursor_data, lang)
  local file = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())

  lang = lang or ''
  local parts = {
    string.format('[CURSOR POSITION]: File %s ,Line %d, Column %d', file, cursor_data.line, cursor_data.column),
  }

  if cursor_data.lines_before and #cursor_data.lines_before > 0 then
    table.insert(parts, '[BEFORE CURSOR]:')
    table.insert(parts, '```' .. lang)
    table.insert(parts, table.concat(cursor_data.lines_before, '\n'))
    table.insert(parts, '```')
  end

  table.insert(parts, '[CURRENT LINE]:')
  table.insert(parts, '```' .. lang)
  table.insert(parts, cursor_data.line_content)
  table.insert(parts, '```')

  if cursor_data.lines_after and #cursor_data.lines_after > 0 then
    table.insert(parts, '[AFTER CURSOR]:')
    table.insert(parts, '```' .. lang)
    table.insert(parts, table.concat(cursor_data.lines_after, '\n'))
    table.insert(parts, '```')
  end

  return table.concat(parts, '\n')
end

---@param diff_text string
---@return string
local function format_git_diff(diff_text)
  return '[GIT DIFF] (staged changes):\n```diff\n' .. diff_text .. '\n```'
end

---@param buf integer
---@param lang string|nil
---@return string
local function format_buffer(buf, lang)
  lang = lang or ''
  local file = vim.api.nvim_buf_get_name(buf)
  local rel_path = vim.fn.fnamemodify(file, ':~:.')
  local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')

  return string.format('[FILE]: %s\n\n```%s\n%s\n```', rel_path, lang, content)
end

---@return integer|nil, integer|nil
function M.get_current_buf()
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  return buf, win
end

--- Formats context as plain text for LLM consumption (used by quick chat)
--- Unlike ChatContext, this outputs human-readable text instead of structured JSON
---@param prompt string The user's instruction/prompt
---@param opts? { range?: { start: integer, stop: integer }, context_config?: OpencodeContextConfig }
---@return table result { text: string, parts: OpencodeMessagePart[] }
M.format_message = Promise.async(function(prompt, opts)
  opts = opts or {}
  local context_config = opts.context_config
  local buf, win = M.get_current_buf()

  if not buf or not win then
    return {
      text = '[USER PROMPT]: ' .. prompt,
      parts = { { type = 'text', text = '[USER PROMPT]: ' .. prompt } },
    }
  end

  local range = opts.range
  local file_name = vim.api.nvim_buf_get_name(buf)
  local lang = util.get_markdown_filetype(file_name) or vim.fn.fnamemodify(file_name, ':e') or ''

  local text_parts = {}

  if base_context.is_context_enabled('selection', context_config) then
    local selections = {}

    if range and range.start and range.stop then
      local file = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ':~:.')
      if file then
        local selection = base_context.new_selection(
          {
            name = file,
            path = vim.api.nvim_buf_get_name(buf),
            extension = vim.fn.fnamemodify(file, ':e'),
          },
          table.concat(vim.api.nvim_buf_get_lines(buf, range.start - 1, range.stop, false), '\n'),
          string.format('%d-%d', range.start, range.stop),
          true
        )
        table.insert(selections, selection)
      end
    end

    for _, sel in ipairs(selections) do
      table.insert(text_parts, '')
      table.insert(text_parts, format_selection(sel))
    end
  end

  if base_context.is_context_enabled('buffer', context_config) then
    table.insert(text_parts, format_buffer(buf, lang))
  end

  local diag_range = nil
  if range then
    diag_range = { start_line = range.start - 1, end_line = range.stop - 1 }
  end
  local diagnostics = base_context.get_diagnostics(buf, context_config, diag_range)
  if diagnostics and #diagnostics > 0 then
    local formatted_diag = format_diagnostics(diagnostics, nil) -- No need to filter again
    if formatted_diag then
      table.insert(text_parts, '')
      table.insert(text_parts, formatted_diag)
    end
  end

  if base_context.is_context_enabled('cursor_data', context_config) then
    local cursor_data = base_context.get_current_cursor_data(buf, win, context_config)
    if cursor_data then
      table.insert(text_parts, '')
      table.insert(text_parts, format_cursor_data(cursor_data, lang))
    end
  end

  if base_context.is_context_enabled('git_diff', context_config) then
    local diff_text = base_context.get_git_diff(context_config):await()
    if diff_text and diff_text ~= '' then
      table.insert(text_parts, '')
      table.insert(text_parts, format_git_diff(diff_text))
    end
  end

  table.insert(text_parts, '')
  table.insert(text_parts, '[USER PROMPT]: ' .. prompt)

  local full_text = table.concat(text_parts, '\n')

  return {
    text = full_text,
    parts = { { type = 'text', text = full_text } },
  }
end)

return M
