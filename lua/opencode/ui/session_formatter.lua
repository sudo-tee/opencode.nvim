local context_module = require('opencode.context')
local util = require('opencode.util')
local Output = require('opencode.ui.output')
local state = require('opencode.state')

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
    M._format_message_header(M._messages[i])

    local msg = M._messages[i]
    for j, part in ipairs(msg.parts or {}) do
      M._current = { msg_idx = i, part_idx = j, role = msg.role, type = part.type }
      M._output:add_metadata(M._current)

      if part.type == 'text' and part.text then
        if msg.role == 'user' then
          M._format_user_message(vim.trim(part.text))
        elseif msg.role == 'assistant' then
          M._format_assistant_message(vim.trim(part.text))
        end
      elseif part.type == 'tool' then
        M._format_tool(part)
      end
      M._output:add_empty_line()
    end
    if msg.error and msg.error ~= '' then
      M._format_error(msg)
    end

    M._output:add_lines(M.separator)
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

function M.get_lines()
  return M._output:get_lines()
end

function M._format_error(message)
  M._output:add_empty_line()
  M._format_callout('ERROR', message.error.data.message, message.error.name)
end

function M._format_message_header(message)
  local role = message.role or 'unknown'
  local callout = message.role == 'user' and 'QUESTION' or 'SUMMARY'
  local time = message.time and message.time.created or nil
  local title = '> [!' .. callout .. '] ' .. role:upper() .. (time and ' (' .. util.time_ago(time) .. ')' or '')
  M._output:add_empty_line()
  M._output:add_line(title)
end

function M._format_callout(callout, text, title)
  title = title and title .. ' ' or ''
  local win_width = vim.api.nvim_win_get_width(state.windows.output_win)
  if #text > win_width - 4 then
    text = vim.fn.substitute(text, '\\v(.{1,' .. (win_width - 8) .. '})', '\\1\\n', 'g')
  end

  local lines = vim.split(text, '\n')
  if #lines == 1 and title == '' then
    M._output:add_line('> [!' .. callout .. '] ' .. lines[1])
  else
    M._output:add_line('> [!' .. callout .. ']' .. title)
    M._output:add_line('>')
    M._output:add_lines(lines, nil, '> ')
  end
end

function M._format_user_message(text)
  local context = context_module.extract_from_message(text)

  M._output:add_line('>')
  M._output:add_lines(vim.split(context.prompt, '\n'), nil, '> ')

  if context.selected_text then
    M._output:add_lines(vim.split(context.selected_text, '\n'), nil, '> ')
  end
end

---@param text string
function M._format_assistant_message(text)
  M._output:add_empty_line()
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
  local tool = part.tool
  if not tool then
    return
  end

  local input = part.state.input
  local file_name = input and vim.fn.fnamemodify(input.filePath, ':t') or ''

  if tool == 'bash' then
    M._format_context('💻 run', input and input.description)

    if part.state.metadata.stdout then
      M._format_code('> ' .. input.command .. '\n\n' .. part.state.metadata.stdout, 'bash')
    end
  elseif tool == 'read' then
    M._format_context('👀 read', file_name)
  elseif tool == 'edit' then
    M._format_context('✏️ edit file', file_name)

    if part.state.metadata.diff then
      M._format_diff(part.state.metadata.diff)
    end
  elseif tool == 'todowrite' then
    M._output:add_line('| 📃 PLAN `' .. (part.state.title or '') .. '`|')
    M._output:add_line('|---|')
    for _, item in ipairs(input.todos or {}) do
      local statuses = {
        in_progress = '⌛',
        completed = '✅',
        pending = '▢ ',
      }

      M._output:add_line(string.format('| [%s] %s |', statuses[item.status], item.content))
    end
    M._output:add_line('<!--- end of todo list -->')
  else
    M._format_context('🔧 tool', tool)
  end
  if part.state.metadata.error then
    M._format_callout('ERROR', part.state.metadata.message)
  end
  M._output:add_empty_line()
end

function M._format_code(code, language)
  M.wrap_block(vim.split(code, '\n'), '```' .. (language or ''), '```')
end

function M._format_diff(code)
  local lines = vim.split(code, '\n')
  if #lines > 4 then
    lines = vim.list_slice(lines, 5)
  end
  M.wrap_block(lines, '```diff lua', '```')
end

function M.wrap_block(lines, top, bottom)
  M._output:add_empty_line()
  M._output:add_line(top)
  M._output:add_lines(lines)
  M._output:add_line(bottom or top)
  M._output:add_empty_line()
end

return M
