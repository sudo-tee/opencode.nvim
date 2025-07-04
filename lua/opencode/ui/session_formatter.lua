local M = {}

local context_module = require('opencode.context')

M.separator = {
  '---',
  '',
}

function M.add_empty_line(lines, prefix)
  if lines[#lines] ~= '' and lines[#lines] ~= prefix then
    table.insert(lines, prefix or '')
  end
end

function M.format_session(session)
  if not session or session == '' then
    return nil
  end

  local session_lines = require('opencode.session').get_messages(session)
  if session_lines == nil or #session_lines == 0 then
    return nil
  end

  local output_lines = { '' }

  local need_separator = false

  for i = 1, #session_lines do
    local message = session_lines[i]

    local message_lines = M._format_message(message)
    if message_lines then
      if need_separator then
        vim.list_extend(output_lines, M.separator)
      else
        need_separator = true
      end

      vim.list_extend(output_lines, message_lines)
    end
  end

  return output_lines
end

function M._format_user_message(lines, text)
  table.insert(lines, '---')
  local context = context_module.extract_from_message(text)
  for _, line in ipairs(vim.split(context.prompt, '\n')) do
    if _ == 1 then
      line = '💬 ' .. line
    end
    table.insert(lines, '> ' .. line)
  end

  if context.selected_text then
    M.add_empty_line(lines, '> ')
    for _, line in ipairs(vim.split(context.selected_text, '\n')) do
      table.insert(lines, '> ' .. line)
    end
  end
end

function M._format_message(message)
  if not message.parts then
    return nil
  end

  local lines = {}

  for _, part in ipairs(message.parts) do
    if part.type == 'text' and part.text then
      local text = vim.trim(part.text)
      if message.role == 'user' then
        M._format_user_message(lines, text)
      elseif message.role == 'assistant' then
        M._format_assistant_message(lines, text)
      end
    elseif part.type == 'tool-invocation' then
      M._format_tool(lines, part, message)
    end
  end

  return lines
end

---@param lines table
---@param text string
function M._format_assistant_message(lines, text)
  ---@TODO: properly merge text parts
  if #lines > 0 and lines[#lines] ~= '' and not text:find('\n') then
    lines[#lines] = lines[#lines] .. text
  else
    vim.list_extend(lines, vim.split(text, '\n'))
  end
end

function M._format_context(lines, type, value, ref)
  if not type or not value then
    return
  end

  local formatted_action = '**' .. type .. '** ` ' .. value .. ' ` <!--[' .. (ref or '') .. ']-->'
  table.insert(lines, formatted_action)
end

function M._format_tool(lines, part, _message)
  M.add_empty_line(lines)
  local tool = part.toolInvocation
  if not tool then
    return
  end
  local args = tool.args or {}
  local path = args.filePath
  local file_name = path and vim.fn.fnamemodify(path, ':t') or ''
  local file_type = path and vim.fn.fnamemodify(path, ':e') or ''

  if tool.toolName == 'bash' then
    M._format_context(lines, '🚀 run', args.command, tool.toolCallId)
  elseif tool.toolName == 'read' then
    M._format_context(lines, '👀 read', file_name, tool.toolCallId)
  elseif tool.toolName == 'edit' then
    M._format_context(lines, '✏️ edit file', file_name, tool.toolCallId)
    if not args.newString or args.newString == '' then
      return
    end
    M._format_code(lines, args.newString, file_type)
  else
    M._format_context(lines, '🔧 tool', tool.toolName, tool.toolCallId)
  end
  M.add_empty_line(lines)
end

function M._format_code(lines, code, language)
  table.insert(lines, '```' .. (language or ''))
  for _, line in ipairs(vim.split(code, '\n')) do
    table.insert(lines, line)
  end
  table.insert(lines, '```')
  M.add_empty_line(lines)
end

return M
