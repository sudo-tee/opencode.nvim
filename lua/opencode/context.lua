-- Gathers editor context

local template = require('opencode.template')
local util = require('opencode.util')
local config = require('opencode.config')

local M = {}

M.context = {
  -- current file
  current_file = nil,
  cursor_data = nil,

  -- attachments
  mentioned_files = nil,
  mentioned_files_content = nil,
  selections = nil,
  linter_errors = nil,
  mentioned_subagents = nil,
}

function M.unload_attachments()
  M.context.mentioned_files = nil
  M.context.mentioned_files_content = nil
  M.context.selections = nil
  M.context.linter_errors = nil
end

function M.load()
  if util.is_current_buf_a_file() then
    local current_file = M.get_current_file()
    local cursor_data = M.get_current_cursor_data()

    M.context.current_file = current_file
    M.context.cursor_data = cursor_data
    M.context.linter_errors = M.check_linter_errors()
  end

  local current_selection = M.get_current_selection()
  if current_selection then
    local selection = M.new_selection(M.context.current_file, current_selection.text, current_selection.lines)
    M.add_selection(selection)
  end
end

function M.check_linter_errors()
  local diagnostic_conf = config.get('context') and config.get('context').diagnostics
  if not diagnostic_conf then
    return nil
  end
  local severity_levels = {}
  if diagnostic_conf.error then
    table.insert(severity_levels, vim.diagnostic.severity.ERROR)
  end
  if diagnostic_conf.warning then
    table.insert(severity_levels, vim.diagnostic.severity.WARN)
  end
  if diagnostic_conf.info then
    table.insert(severity_levels, vim.diagnostic.severity.INFO)
  end

  local diagnostics = vim.diagnostic.get(0, { severity = severity_levels })
  if #diagnostics == 0 then
    return nil
  end

  local message = 'Found ' .. #diagnostics .. ' error' .. (#diagnostics > 1 and 's' or '') .. ':'

  for i, diagnostic in ipairs(diagnostics) do
    local line_number = diagnostic.lnum + 1 -- Convert to 1-based line numbers
    local short_message = diagnostic.message:gsub('%s+', ' '):gsub('^%s', ''):gsub('%s$', '')
    message = message .. '\n Line ' .. line_number .. ': ' .. short_message
  end

  return message
end

function M.new_selection(file, content, lines)
  return {
    file = file,
    content = util.indent_code_block(content),
    lines = lines,
  }
end

function M.add_selection(selection)
  if not M.context.selections then
    M.context.selections = {}
  end

  table.insert(M.context.selections, selection)
end

function M.add_file(file)
  if not M.context.mentioned_files then
    M.context.mentioned_files = {}
  end

  if vim.fn.filereadable(file) ~= 1 then
    vim.notify('File not added to context. Could not read.')
    return
  end

  if not vim.tbl_contains(M.context.mentioned_files, file) then
    table.insert(M.context.mentioned_files, file)
  end
end

function M.add_subagent(subagent)
  if not M.context.mentioned_subagents then
    M.context.mentioned_subagents = {}
  end

  if not vim.tbl_contains(M.context.mentioned_subagents, subagent) then
    table.insert(M.context.mentioned_subagents, subagent)
  end
end

function M.delta_context()
  local context = vim.deepcopy(M.context)
  local last_context = require('opencode.state').last_sent_context
  if not last_context then
    return context
  end

  -- no need to send file context again
  if context.current_file and context.current_file.name == last_context and last_context.current_file.name then
    context.current_file = nil
  end
  -- no need to send subagents again
  if
    context.mentioned_subagents
    and last_context.mentioned_subagents
    and vim.deep_equal(context.mentioned_subagents, last_context.mentioned_subagents)
  then
    context.mentioned_subagents = nil
  end

  return context
end

function M.get_current_file()
  local file = vim.fn.expand('%:p')
  if not file or file == '' or vim.fn.filereadable(file) ~= 1 then
    return nil
  end
  return {
    path = file,
    name = vim.fn.fnamemodify(file, ':t'),
    extension = vim.fn.fnamemodify(file, ':e'),
  }
end

function M.get_current_cursor_data()
  if not (config.get('context') and config.get('context').cursor_data) then
    return nil
  end

  local cursor_pos = vim.fn.getcurpos()
  local cursor_content = vim.trim(vim.api.nvim_get_current_line())
  return { line = cursor_pos[2], col = cursor_pos[3], line_content = cursor_content }
end

function M.get_current_selection()
  -- Return nil if not in a visual mode
  if not vim.fn.mode():match('[vV\022]') then
    return nil
  end

  -- Save current position and register state
  local current_pos = vim.fn.getpos('.')
  local old_reg = vim.fn.getreg('x')
  local old_regtype = vim.fn.getregtype('x')

  -- Capture selection text and position
  vim.cmd('normal! "xy')
  local text = vim.fn.getreg('x')

  -- Get line numbers
  vim.cmd('normal! `<')
  local start_line = vim.fn.line('.')
  vim.cmd('normal! `>')
  local end_line = vim.fn.line('.')

  -- Restore state
  vim.fn.setreg('x', old_reg, old_regtype)
  vim.cmd('normal! gv')
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'nx', true)
  vim.fn.setpos('.', current_pos)

  return {
    text = text and text:match('[^%s]') and text or nil,
    lines = start_line .. ', ' .. end_line,
  }
end

function M.format_message(prompt)
  local context = nil

  context = M.delta_context()

  context.prompt = prompt
  for _, file in ipairs(context.mentioned_files or {}) do
    context.mentioned_files_content = context.mentioned_files_content or {}
    context.mentioned_files_content[file] = util.read_file_content(file, true)
  end
  return template.render_template(context)
end

function M.extract_from_message(text)
  local current_file = template.extract_tag('current-file', text)
  local context = {
    prompt = template.extract_tag('user-query', text) or text,
    selected_text = template.extract_tag('manually-added-selection', text),
    current_file = current_file and current_file:match('Path: (.+)') or nil,
  }
  return context
end

return M
