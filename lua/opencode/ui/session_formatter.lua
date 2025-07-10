local context_module = require('opencode.context')
local util = require('opencode.util')
local Output = require('opencode.ui.output')
local state = require('opencode.state')

local M = {
  output = Output.new(),
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

  M.output:clear()

  M.output:add_line('')
  M.output:add_line('')

  for i = 1, #M._messages do
    M.output:add_lines(M.separator)

    M._format_message_header(M._messages[i])

    local msg = M._messages[i]
    for j, part in ipairs(msg.parts or {}) do
      M._current = { msg_idx = i, part_idx = j, role = msg.role, type = part.type }
      M.output:add_metadata(M._current)

      if part.type == 'text' and part.text then
        if msg.role == 'user' then
          M._format_user_message(vim.trim(part.text))
        elseif msg.role == 'assistant' then
          M._format_assistant_message(vim.trim(part.text))
        end
      elseif part.type == 'tool' then
        M._format_tool(part)
      end
      M.output:add_empty_line()
    end

    if msg.error and msg.error ~= '' then
      M._format_error(msg)
    end
  end

  return M.output:get_lines()
end

function M.get_message_at_line(line)
  for i = line, 1, -1 do
    local metadata = M.output:get_metadata(i)
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
  return M.output:get_lines()
end

function M._format_error(message)
  M.output:add_empty_line()
  M._format_callout('ERROR', message.error.data.message, message.error.name)
end

function M._format_message_header(message)
  local role = message.role or 'unknown'
  local icon = message.role == 'user' and '▌💬' or '🤖'

  local time = message.time and message.time.created or nil
  local time_text = (time and ' (' .. util.time_ago(time) .. ')' or '')
  local role_hl = 'OpencodeMessageRole' .. role:sub(1, 1):upper() .. role:sub(2)

  M.output:add_empty_line()
  M.output:add_extmark(M.output:get_line_count(), {
    virt_text = {
      { icon, role_hl },
      { ' ' },
      { role:upper(), role_hl },
      { time_text, 'Comment' },
    },
    virt_text_win_col = -3,
    priority = 10,
  })

  M.output:add_line('')
end

function M._format_callout(callout, text, title)
  title = title and title .. ' ' or ''
  local win_width = vim.api.nvim_win_get_width(state.windows.output_win)
  if #text > win_width - 4 then
    text = vim.fn.substitute(text, '\\v(.{1,' .. (win_width - 8) .. '})', '\\1\\n', 'g')
  end

  local lines = vim.split(text, '\n')
  if #lines == 1 and title == '' then
    M.output:add_line('> [!' .. callout .. '] ' .. lines[1])
  else
    M.output:add_line('> [!' .. callout .. ']' .. title)
    M.output:add_line('>')
    M.output:add_lines(lines, nil, '> ')
  end
end

function M._format_user_message(text)
  local context = context_module.extract_from_message(text)
  local start_line = M.output:get_line_count() - 1

  M.output:add_empty_line()
  M.output:add_lines(vim.split(context.prompt, '\n'), nil)

  if context.selected_text then
    M.output:add_lines(vim.split(context.selected_text, '\n'), nil)
  end

  if context.current_file then
    M.output:add_empty_line()
    local path = context.current_file
    if vim.startswith(path, vim.fn.getcwd()) then
      path = path:sub(#vim.fn.getcwd() + 2)
    end
    M.output:add_line(string.format('[%s](%s)', path, context.current_file))
  end

  local end_line = M.output:get_line_count()

  M._add_vertical_border(start_line, end_line, 'OpencodeMessageRoleUser', -3)
end

---@param text string
function M._format_assistant_message(text)
  M.output:add_empty_line()
  M.output:add_lines(vim.split(text, '\n'))
end

function M._format_action(type, value)
  if not type or not value then
    return
  end

  local formatted_action = '**' .. type .. '** ` ' .. value .. ' `'
  M.output:add_line(formatted_action)
end

function M._format_bash_tool(input, metadata)
  M._format_action('💻 run', input and input.description)
  if metadata.stdout then
    M._format_code('> ' .. input.command .. '\n\n' .. metadata.stdout, 'bash')
  end
end

function M._format_file_tool(tool_type, input, metadata)
  local file_name = input and vim.fn.fnamemodify(input.filePath, ':t') or ''
  local file_type = input and vim.fn.fnamemodify(input.filePath, ':e') or ''
  local icons = {
    read = '👀 read',
    edit = '✏️ edit file',
    write = '📝 write file',
  }

  M._format_action(icons[tool_type], file_name)

  if tool_type == 'edit' and metadata.diff then
    M._format_diff(metadata.diff, file_type)
  elseif tool_type == 'write' and input and input.content then
    M._format_code(input.content, file_type)
  end
end

function M._format_todo_tool(part)
  M._format_action('📃 plan', (part.state.title or ''))
  M.output:add_empty_line()

  local todos = part.state and part.state.input and part.state.input.todos

  for _, item in ipairs(todos or {}) do
    local statuses = { in_progress = '-', completed = 'x', pending = ' ' }
    M.output:add_line(string.format('- [%s] %s ', statuses[item.status], item.content), nil, true)
  end
end

function M._format_glob_tool(input, metadata)
  M._format_action('🔍 glob', input and input.pattern)
  local prefix = metadata.truncated and ' more than' or ''
  M.output:add_line(string.format('Found%s `%d` file(s):', prefix, metadata.count or 0))
end

function M._format_webfetch_tool(input)
  M._format_action('🌐 fetch', input and input.url)
end

function M._format_tool(part)
  M.output:add_empty_line()
  local tool = part.tool
  if not tool then
    return
  end

  local start_line = M.output:get_line_count() + 1
  local input = part.state and part.state.input
  local metadata = part.state.metadata or {}

  if tool == 'bash' then
    M._format_bash_tool(input, metadata)
  elseif tool == 'read' or tool == 'edit' or tool == 'write' then
    M._format_file_tool(tool, input, metadata)
  elseif tool == 'todowrite' then
    M._format_todo_tool(part)
  elseif tool == 'glob' then
    M._format_glob_tool(input, metadata)
  elseif tool == 'webfetch' then
    M._format_webfetch_tool(input)
  else
    M._format_action('🔧 tool', tool)
  end

  if metadata.error then
    M._format_callout('ERROR', metadata.message)
  end

  M.output:add_empty_line()

  local end_line = M.output:get_line_count()
  if end_line - start_line > 1 then
    M._add_vertical_border(start_line, end_line - 1, 'OpencodeToolBorder', -1)
  end
end

function M._format_code(code, language)
  M.wrap_block(vim.split(code, '\n'), '```' .. (language or ''), '```')
end

function M._format_diff(code, file_type)
  local win_width = vim.api.nvim_win_get_width(state.windows.output_win)
  M.output:add_empty_line()
  M.output:add_line('```' .. file_type)
  local lines = vim.split(code, '\n')
  if #lines > 5 then
    lines = vim.list_slice(lines, 6)
  end

  M.output:add_empty_line()

  for _, line in ipairs(lines) do
    local line_idx = M.output:get_line_count() + 1

    local first_char = line:sub(1, 1)
    if first_char == '+' or first_char == '-' then
      local hl_group = first_char == '+' and 'OpencodeDiffAdd' or 'OpencodeDiffDelete'
      M.output:add_line(' ' .. line:sub(2))
      M.output:add_extmark(line_idx, {
        virt_text = { { line .. string.rep(' ', win_width - #line), hl_group } },
        virt_text_pos = 'overlay',
        hl_mode = 'combine',
      })
    else
      M.output:add_line(line)
    end
  end
  M.output:add_line('```')
  M.output:add_empty_line()
end

function M._add_vertical_border(start_line, end_line, hl_group, win_col)
  for line = start_line, end_line do
    M.output:add_extmark(line, {
      virt_text = { { '▌', hl_group } },
      virt_text_pos = 'inline',
      virt_text_win_col = win_col,
      virt_text_repeat_linebreak = true,
    })
  end
end

function M.wrap_block(lines, top, bottom)
  M.output:add_empty_line()
  M.output:add_line(top)
  M.output:add_lines(lines)
  M.output:add_line(bottom or top)
  M.output:add_empty_line()
end

return M
