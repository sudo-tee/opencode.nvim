-- JSON formatter for context
-- Outputs JSON-formatted context parts for the opencode API

local util = require('opencode.util')

local M = {}

---@param path string
---@param prompt? string
---@return OpencodeMessagePart
function M.format_file_part(path, prompt)
  local rel_path = vim.fn.fnamemodify(path, ':~:.')
  local mention = '@' .. rel_path
  local pos = prompt and prompt:find(mention)
  pos = pos and pos - 1 or 0 -- convert to 0-based index

  local ext = vim.fn.fnamemodify(path, ':e'):lower()
  local mime_type = 'text/plain'
  if ext == 'png' then
    mime_type = 'image/png'
  elseif ext == 'jpg' or ext == 'jpeg' then
    mime_type = 'image/jpeg'
  elseif ext == 'gif' then
    mime_type = 'image/gif'
  elseif ext == 'webp' then
    mime_type = 'image/webp'
  end

  local file_part = { filename = rel_path, type = 'file', mime = mime_type, url = 'file://' .. path }
  if prompt then
    file_part.source = {
      path = path,
      type = 'file',
      text = { start = pos, value = mention, ['end'] = pos + #mention },
    }
  end
  return file_part
end

---@param selection OpencodeContextSelection
---@return OpencodeMessagePart
function M.format_selection_part(selection)
  local lang = util.get_markdown_filetype(selection.file and selection.file.name or '') or ''

  return {
    type = 'text',
    metadata = {
      context_type = 'selection',
    },
    text = vim.json.encode({
      context_type = 'selection',
      file = selection.file,
      content = string.format('`````%s\n%s\n`````', lang, selection.content),
      lines = selection.lines,
    }),
    synthetic = true,
  }
end

---@param diagnostics OpencodeDiagnostic[]
---@param range? { start_line: integer, end_line: integer }|nil
---@return OpencodeMessagePart
function M.format_diagnostics_part(diagnostics, range)
  local diag_list = {}
  for _, diag in ipairs(diagnostics) do
    if not range or (diag.lnum >= range.start_line and diag.lnum <= range.end_line) then
      local short_msg = diag.message:gsub('%s+', ' '):gsub('^%s', ''):gsub('%s$', '')
      table.insert(
        diag_list,
        { msg = short_msg, severity = diag.severity, pos = 'l' .. diag.lnum + 1 .. ':c' .. diag.col + 1 }
      )
    end
  end
  return {
    type = 'text',
    metadata = {
      context_type = 'diagnostics',
    },
    text = vim.json.encode({ context_type = 'diagnostics', content = diag_list }),
    synthetic = true,
  }
end

---@param cursor_data table
---@param get_current_buf fun(): integer|nil Function to get current buffer
---@return OpencodeMessagePart
function M.format_cursor_data_part(cursor_data, get_current_buf)
  local buf = (get_current_buf() or 0) --[[@as integer]]
  local lang = util.get_markdown_filetype(vim.api.nvim_buf_get_name(buf)) or ''
  return {
    type = 'text',
    metadata = {
      context_type = 'cursor-data',
      lang = lang,
    },
    text = vim.json.encode({
      context_type = 'cursor-data',
      line = cursor_data.line,
      column = cursor_data.column,
      line_content = string.format('`````%s\n%s\n`````', lang, cursor_data.line_content),
      lines_before = cursor_data.lines_before,
      lines_after = cursor_data.lines_after,
    }),
    synthetic = true,
  }
end

---@param agent string
---@param prompt string
---@return OpencodeMessagePart
function M.format_subagents_part(agent, prompt)
  local mention = '@' .. agent
  local pos = prompt:find(mention)
  pos = pos and pos - 1 or 0 -- convert to 0-based index

  return {
    type = 'agent',
    name = agent,
    source = { value = mention, start = pos, ['end'] = pos + #mention },
  }
end

---@param buf integer
---@return OpencodeMessagePart
function M.format_buffer_part(buf)
  local file = vim.api.nvim_buf_get_name(buf)
  local rel_path = vim.fn.fnamemodify(file, ':~:.')
  return {
    type = 'text',
    text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'),
    metadata = {
      context_type = 'file-content',
      filename = rel_path,
      mime = 'text/plain',
    },
    synthetic = true,
  }
end

---@param diff_text string
---@return OpencodeMessagePart
function M.format_git_diff_part(diff_text)
  return {
    type = 'text',
    metadata = {
      context_type = 'git-diff',
    },
    text = diff_text,
    synthetic = true,
  }
end

return M
