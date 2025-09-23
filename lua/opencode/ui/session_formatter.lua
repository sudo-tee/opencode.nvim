local context_module = require('opencode.context')
local icons = require('opencode.ui.icons')
local util = require('opencode.util')
local Output = require('opencode.ui.output')
local state = require('opencode.state')
local config = require('opencode.config').get()
local snapshot = require('opencode.snapshot')

local M = {
  output = Output.new(),
  _messages = {},
  _current = nil,
}

M.separator = {
  '---',
  '',
}

---@param session Session Session ID
---@return string[]|nil Formatted session lines
function M.format_session(session)
  if not session or session == '' then
    return nil
  end

  state.messages = require('opencode.session').get_messages(session) or {}

  M.output:clear()

  M.output:add_line('')
  M.output:add_line('')

  for i, msg in ipairs(state.messages) do
    M.output:add_lines(M.separator)
    state.current_message = msg

    if not state.current_model and msg.providerID and msg.providerID ~= '' then
      state.current_model = msg.providerID .. '/' .. msg.modelID
    end

    if msg.tokens and msg.tokens.input > 0 then
      state.tokens_count = msg.tokens.input + msg.tokens.output + msg.tokens.cache.read + msg.tokens.cache.write
    end

    if msg.cost and type(msg.cost) == 'number' then
      state.cost = msg.cost
    end

    M._format_message_header(msg, i)

    for j, part in ipairs(msg.parts or {}) do
      M._current = { msg_idx = i, part_idx = j, role = msg.role, type = part.type, snapshot = part.snapshot }
      M.output:add_metadata(M._current)

      if part.type == 'text' and part.text then
        if msg.role == 'user' and not part.synthetic == true then
          M._format_user_message(vim.trim(part.text), msg)
        elseif msg.role == 'assistant' then
          M._format_assistant_message(vim.trim(part.text))
        end
      elseif part.type == 'tool' then
        M._format_tool(part)
      elseif part.type == 'patch' and part.hash then
        M._format_patch(part)
      end
      M.output:add_empty_line()
    end

    if msg.error and msg.error ~= '' then
      M._format_error(msg)
    end
  end

  M.output:add_empty_line()
  return M.output:get_lines()
end

---@param line number Buffer line number
---@return {message: Message, part: MessagePart, type: string, msg_idx: number, part_idx: number}|nil
function M.get_message_at_line(line)
  local metadata = M.output:get_nearest_metadata(line)
  if metadata and metadata.msg_idx and metadata.part_idx then
    local msg = state.messages[metadata.msg_idx]
    local part = msg.parts[metadata.part_idx]
    return {
      message = msg,
      part = part,
      msg_idx = metadata.msg_idx,
      part_idx = metadata.part_idx,
    }
  end
end

---@return string[] Lines from the current output
function M.get_lines()
  return M.output:get_lines()
end

function M._format_patch(part)
  local restore_points = snapshot.get_restore_points_by_parent(part.hash)
  M.output:add_empty_line()
  M._format_action(icons.get('snapshot') .. ' **Created Snapshot**', vim.trim(part.hash:sub(1, 8)))
  M.output:add_action({
    text = '[R]evert file',
    type = 'diff_revert_selected_file',
    args = { part.hash },
    key = 'R',
  })
  M.output:add_action({
    text = 'Revert [A]ll',
    type = 'diff_revert_all',
    args = { part.hash },
    key = 'A',
  })
  M.output:add_action({
    text = '[D]iff',
    type = 'diff_open',
    args = { part.hash },
    key = 'D',
  })

  if #restore_points > 0 then
    for _, restore_point in ipairs(restore_points) do
      M.output:add_line(
        string.format(
          '  %s Restore point `%s` - %s',
          icons.get('restore_point'),
          restore_point.id:sub(1, 8),
          util.time_ago(restore_point.created_at)
        )
      )
      M.output:add_action({
        text = 'Restore [A]ll',
        type = 'diff_restore_snapshot_all',
        args = { part.hash },
        key = 'A',
      })
      M.output:add_action({
        text = '[R]estore file',
        type = 'diff_restore_snapshot_file',
        args = { part.hash },
        key = 'R',
      })
    end
  end
end

---@param message Message
function M._format_error(message)
  M.output:add_empty_line()
  M._format_callout('ERROR', vim.inspect(message.error))
end

---@param message Message
function M._format_message_header(message, msg_idx)
  local role = message.role or 'unknown'
  local icon = message.role == 'user' and icons.get('header_user') or icons.get('header_assistant')

  local time = message.time and message.time.created or nil
  local time_text = (time and ' (' .. util.time_ago(time) .. ')' or '')
  local role_hl = 'OpencodeMessageRole' .. role:sub(1, 1):upper() .. role:sub(2)
  local moder_text = message.modelID and ' ' .. message.modelID or ''

  M.output:add_empty_line()
  M.output:add_metadata({ msg_idx = msg_idx, part_idx = 1, role = role, type = 'header' })
  M.output:add_extmark(M.output:get_line_count(), {
    virt_text = {
      { icon, role_hl },
      { ' ' },
      { role:upper(), role_hl },
      { moder_text, 'OpencodeHint' },
      { time_text, 'OpenCodeHint' },
    },
    virt_text_win_col = -3,
    priority = 10,
  })

  M.output:add_line('')
end

---@param callout string Callout type (e.g., 'ERROR', 'TODO')
function M._format_callout(callout, text, title)
  title = title and title .. ' ' or ''
  local win_width = vim.api.nvim_win_get_width(state.windows.output_win)
  if #text > win_width - 4 then
    local ok, substituted = pcall(vim.fn.substitute, text, '\v(.{' .. (win_width - 8) .. '})', '\1\n', 'g')
    text = ok and substituted or text
  end

  local lines = vim.split(text, '\n')
  if #lines == 1 and title == '' then
    M.output:add_line('> [!' .. callout .. '] ' .. lines[1])
  else
    M.output:add_line('> [!' .. callout .. ']' .. title)
    M.output:add_line('>')
    M.output:add_lines(lines, '> ')
  end
end

---@param text string
---@param message Message
function M._format_user_message(text, message)
  local context = nil
  if vim.startswith(text, '<additional-data>') then
    context = context_module.extract_from_message_legacy(text)
  else
    context = context_module.extract_from_opencode_message(message)
  end

  local start_line = M.output:get_line_count() - 1

  M.output:add_empty_line()
  M.output:add_lines(vim.split(context.prompt, '\n'))

  if context.selected_text then
    M.output:add_lines(vim.split(context.selected_text, '\n'))
  end

  if context.current_file then
    M.output:add_empty_line()
    local path = context.current_file or ''
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

---@param type string Tool type (e.g., 'run', 'read', 'edit', etc.)
function M._format_action(type, value)
  if not type or not value then
    return
  end

  M.output:add_line('**' .. type .. '** ` ' .. value .. ' `')
end

---@param input BashToolInput data for the tool
---@param metadata BashToolMetadata Metadata for the tool use
function M._format_bash_tool(input, metadata)
  M._format_action(icons.get('run') .. ' run', input and input.description)

  if not config.ui.output.tools.show_output then
    return
  end

  if metadata.output then
    M._format_code(vim.split('> ' .. input.command or '' .. '\n\n' .. metadata.output, '\n'), 'bash')
  end
end

---@param tool_type string Tool type (e.g., 'read', 'edit', 'write')
---@param input FileToolInput data for the tool
---@param metadata FileToolMetadata Metadata for the tool use
function M._format_file_tool(tool_type, input, metadata)
  local file_name = input and vim.fn.fnamemodify(input.filePath, ':t') or ''
  local file_type = input and vim.fn.fnamemodify(input.filePath, ':e') or ''
  local icons = { read = icons.get('read'), edit = icons.get('edit'), write = icons.get('write') }

  M._format_action(icons[tool_type] .. ' ' .. tool_type, file_name)

  if not config.ui.output.tools.show_output then
    return
  end

  if tool_type == 'edit' and metadata.diff then
    M._format_diff(metadata.diff, file_type)
  elseif tool_type == 'write' and input and input.content then
    M._format_code(vim.split(input.content, '\n'), file_type)
  end
end

---@param title string
---@param input TodoToolInput
function M._format_todo_tool(title, input)
  M._format_action(icons.get('plan') .. ' plan', (title or ''))
  if not config.ui.output.tools.show_output then
    return
  end

  M.output:add_empty_line()

  local todos = input and input.todos or {}

  for _, item in ipairs(todos) do
    local statuses = { in_progress = '-', completed = 'x', pending = ' ' }
    M.output:add_line(string.format('- [%s] %s ', statuses[item.status], item.content), true)
  end
end

---@param input GlobToolInput data for the tool
---@param metadata GlobToolMetadata Metadata for the tool use
function M._format_glob_tool(input, metadata)
  M._format_action(icons.get('search') .. ' glob', input and input.pattern)
  if not config.ui.output.tools.show_output then
    return
  end
  local prefix = metadata.truncated and ' more than' or ''
  M.output:add_line(string.format('Found%s `%d` file(s):', prefix, metadata.count or 0))
end

---@param input GrepToolInput data for the tool
---@param metadata GrepToolMetadata Metadata for the tool use
function M._format_grep_tool(input, metadata)
  input = input or { path = '', include = '', pattern = '' }

  local grep_str = string.format('%s `` %s', (input.path or input.include) or '', input.pattern or '')

  M._format_action(icons.get('search') .. ' grep', grep_str)
  if not config.ui.output.tools.show_output then
    return
  end
  local prefix = metadata.truncated and ' more than' or ''
  M.output:add_line(string.format('Found%s `%d` match', prefix, metadata.matches or 0))
end

---@param input WebFetchToolInput data for the tool
function M._format_webfetch_tool(input)
  M._format_action(icons.get('web') .. ' fetch', input and input.url)
end

---@param input ListToolInput
---@param metadata ListToolMetadata
---@param output string
function M._format_list_tool(input, metadata, output)
  M._format_action(icons.get('list') .. ' list', input and input.path or '')
  if not config.ui.output.tools.show_output then
    return
  end
  local lines = vim.split(vim.trim(output or ''), '\n')
  if #lines < 1 or metadata.count == 0 then
    M.output:add_line('No files found.')
    return
  end
  if #lines > 1 then
    M.output:add_line('Files:')
    for i = 2, #lines do
      local file = vim.trim(lines[i])
      if file ~= '' then
        M.output:add_line('  • ' .. file)
      end
    end
  end
  if metadata.truncated then
    M.output:add_line(string.format('Results truncated, showing first %d files', metadata.count or '?'))
  end
end

---@param part MessagePart
function M._format_tool(part)
  M.output:add_empty_line()
  local tool = part.tool
  if not tool then
    return
  end

  local start_line = M.output:get_line_count() + 1
  local input = part.state and part.state.input or {}
  local metadata = part.state.metadata or {}
  local output = part.state and part.state.output or ''

  if tool == 'bash' then
    M._format_bash_tool(input --[[@as BashToolInput]], metadata --[[@as BashToolMetadata]])
  elseif tool == 'read' or tool == 'edit' or tool == 'write' then
    M._format_file_tool(tool, input --[[@as FileToolInput]], metadata --[[@as FileToolMetadata]])
  elseif tool == 'todowrite' then
    M._format_todo_tool(part.state.title, input --[[@as TodoToolInput]])
  elseif tool == 'glob' then
    M._format_glob_tool(input --[[@as GlobToolInput]], metadata --[[@as GlobToolMetadata]])
  elseif tool == 'list' then
    M._format_list_tool(input --[[@as ListToolInput]], metadata --[[@as ListToolMetadata]], output)
  elseif tool == 'grep' then
    M._format_grep_tool(input --[[@as GrepToolInput]], metadata --[[@as GrepToolMetadata]])
  elseif tool == 'webfetch' then
    M._format_webfetch_tool(input --[[@as WebFetchToolInput]])
  elseif tool == 'task' then
    M._format_task_tool(input --[[@as TaskToolInput]], metadata --[[@as TaskToolMetadata]])
  else
    M._format_action(icons.get('tool') .. ' tool', tool)
  end

  if part.state and part.state.status == 'error' then
    M._format_callout('ERROR', part.state.error)
  end

  M.output:add_empty_line()

  local end_line = M.output:get_line_count()
  if end_line - start_line > 1 then
    M._add_vertical_border(start_line, end_line - 1, 'OpencodeToolBorder', -1)
  end
end

---@param input TaskToolInput data for the tool
---@param metadata TaskToolMetadata Metadata for the tool use
function M._format_task_tool(input, metadata)
  M._format_action(icons.get('task') .. ' task', input and input.description)

  if not config.ui.output.tools.show_output then
    return
  end

  if metadata.summary and type(metadata.summary) == 'table' then
    for _, sub_part in ipairs(metadata.summary) do
      if sub_part.type == 'tool' and sub_part.tool then
        M._format_tool(sub_part)
      end
    end
  end
end

function M._format_code(lines, language)
  M.output:add_empty_line()
  M.output:add_line('```' .. (language or ''))
  M.output:add_lines(lines)
  M.output:add_line('```')
  M.output:add_empty_line()
end

function M._format_diff(code, file_type)
  M.output:add_empty_line()
  M.output:add_line('```' .. file_type)
  local lines = vim.split(code, '\n')
  if #lines > 5 then
    lines = vim.list_slice(lines, 6)
  end

  for _, line in ipairs(lines) do
    local first_char = line:sub(1, 1)
    if first_char == '+' or first_char == '-' then
      local hl_group = first_char == '+' and 'OpencodeDiffAdd' or 'OpencodeDiffDelete'
      M.output:add_line(' ' .. line:sub(2))
      local line_idx = M.output:get_line_count()
      M.output:add_extmark(line_idx, function()
        return {
          end_col = 0,
          end_row = line_idx,
          virt_text = { { first_char, { hl_group } } },
          hl_group = hl_group,
          hl_eol = true,
          priority = 5000,
          right_gravity = true,
          end_right_gravity = false,
          virt_text_hide = false,
          virt_text_pos = 'overlay',
          virt_text_repeat_linebreak = false,
        }
      end)
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
      virt_text = { { require('opencode.ui.icons').get('border'), hl_group } },
      virt_text_pos = 'overlay',
      virt_text_win_col = win_col,
      virt_text_repeat_linebreak = true,
    })
  end
end

return M
