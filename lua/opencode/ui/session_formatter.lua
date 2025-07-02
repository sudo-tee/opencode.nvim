local M = {}

local context_module = require('opencode.context')

M.separator = {
  '---',
  '',
}

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
        for _, line in ipairs(M.separator) do
          table.insert(output_lines, line)
        end
      else
        need_separator = true
      end

      vim.list_extend(output_lines, message_lines)
    end
  end

  return output_lines
end

function M._format_user_message(lines, text)
  local context = context_module.extract_from_message(text)
  for _, line in ipairs(vim.split(context.prompt, '\n')) do
    table.insert(lines, '> ' .. line)
  end

  if context.selected_text then
    table.insert(lines, '')
    for _, line in ipairs(vim.split(context.selected_text, '\n')) do
      table.insert(lines, line)
    end
  end
end

function M._format_message(message)
  if not message.parts then
    return nil
  end

  local lines = {}

  for _, part in ipairs(message.parts) do
    if part.type == 'step-start' then
      table.insert(lines, '')
    elseif part.type == 'text' and part.text and part.text ~= '' then
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

  table.insert(lines, '')
  return lines
end

function M._format_assistant_message(lines, text)
  ---@TODO: properly merge text parts
  if #lines > 0 and not text:find('\n') then
    lines[#lines] = lines[#lines] .. text
  else
    vim.list_extend(lines, vim.split(text, '\n'))
  end
end

function M._format_context(lines, type, value)
  if not type or not value then
    return
  end

  value = value:gsub('\n', '\\n')

  local formatted_action = ' **' .. type .. '** ` ' .. value .. ' `'
  table.insert(lines, formatted_action)
end

function M._format_tool(lines, part, _message)
  local tool = part.toolInvocation
  if not tool then
    return
  end
  local args = tool.args or {}
  local path = args.filePath
  local file_name = path and vim.fn.fnamemodify(path, ':t') or ''
  local file_type = path and vim.fn.fnamemodify(path, ':e') or ''

  if tool.toolName == 'bash' then
    M._format_context(lines, '🚀 run', args.command)
  elseif tool.toolName == 'read' then
    M._format_context(lines, '👀 read', file_name)
  elseif tool.toolName == 'edit' then
    M._format_context(lines, '✏️ edit file', file_name)
    M._format_code(lines, args.newString, file_type)
  else
    M._format_context(lines, '🔧 tool', tool.toolName)
  end
end

function M._format_code(lines, code, language)
  table.insert(lines, '')
  table.insert(lines, '```' .. (language or ''))
  for _, line in ipairs(vim.split(code, '\n')) do
    if line ~= '' then
      table.insert(lines, line)
    end
  end
  table.insert(lines, '```')
  table.insert(lines, '')
end

return M
