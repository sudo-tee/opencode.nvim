local context_module = require('opencode.context')
local Output = require('opencode.ui.output')

local M = {
  _output = Output.new(),
  _messages = {},
  _current = nil,
}

M.separator = {
  '---',
  '',
}

function M.format_session(session)
  if not session or session == '' then
    return nil
  end

  M._messages = require('opencode.session').get_messages(session) or {}

  M._output:clear()

  for i = 1, #M._messages do
    local msg = M._messages[i]

    for j, part in ipairs(msg.parts or {}) do
      M._current = { msg_idx = i, part_idx = j, role = msg.role, type = part.type }
      M._output:add_empty_line(M._current)

      if part.type == 'text' and part.text then
        if msg.role == 'user' then
          M._format_user_message(part.text)
        elseif msg.role == 'assistant' then
          M._format_assistant_message(part.text)
        end
      elseif part.type == 'tool-invocation' then
        M._format_tool(part)
      end
    end
  end

  return M._output:get_lines()
end

function M.get_message_at_line(line)
  for i = line, 1, -1 do
    local metadata = M._output:get_metadata(i)
    if metadata and metadata.msg_idx and metadata.part_idx then
      local msg = M._messages[metadata.msg_idx]
      local part = msg.parts[metadata.part_idx]
      return {
        message = msg,
        part = part,
        type = part.type,
        msg_idx = metadata.msg_idx,
        part_idx = metadata.part_idx,
      }
    end
  end
end

function M._format_user_message(text)
  local context = context_module.extract_from_message(text)
  local prompt = '💬 ' .. context.prompt

  M._output:add_empty_line()
  M._output:add_line('---')
  M._output:add_lines(vim.split(prompt, '\n'), nil, '> ')

  if context.selected_text then
    M._output:add_line('> ')
    M._output:add_lines(vim.split(context.selected_text, '\n'), nil, '> ')
  end

  M._output:add_line('---')
  M._output:add_empty_line()
end

---@param text string
function M._format_assistant_message(text)
  ---@TODO: properly merge text parts
  if not text:find('\n') then
    local lines = M._output:get_lines()
    if #lines > 0 and lines[#lines] ~= '' then
      M._output:merge_line(#lines, text)
      return
    end
  end
  M._output:add_lines(vim.split(text, '\n'))
end

function M._format_context(type, value)
  if not type or not value then
    return
  end

  local formatted_action = '**' .. type .. '** ` ' .. value .. ' `'
  M._output:add_line(formatted_action)
end

function M._format_tool(part)
  M._output:add_empty_line()
  local tool = part.toolInvocation
  if not tool then
    return
  end

  local args = tool.args or {}
  local path = args.filePath
  local file_name = path and vim.fn.fnamemodify(path, ':t') or ''
  local file_type = path and vim.fn.fnamemodify(path, ':e') or ''

  if tool.toolName == 'bash' then
    M._format_context('🚀 run', args.command)
  elseif tool.toolName == 'read' then
    M._format_context('👀 read', file_name)
  elseif tool.toolName == 'edit' then
    M._format_context('✏️ edit file', file_name)
    M._format_code(args.newString or '', file_type)
  else
    M._format_context('🔧 tool', tool.toolName)
  end
  M._output:add_empty_line()
end

function M._format_code(code, language)
  M.wrap_block(vim.split(code, '\n'), '```' .. (language or ''), '```')
end

function M.wrap_block(lines, top, bottom)
  M._output:add_empty_line()
  M._output:add_line(top)
  M._output:add_lines(lines)
  M._output:add_line(bottom or top)
  M._output:add_empty_line()
end

return M
