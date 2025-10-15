local context_module = require('opencode.context')
local icons = require('opencode.ui.icons')
local util = require('opencode.util')
local Output = require('opencode.ui.output')
local state = require('opencode.state')
local config = require('opencode.config')
local snapshot = require('opencode.snapshot')
local Promise = require('opencode.promise')

local M = {}

M.separator = {
  '----',
  '',
}

---@param session Session Session ID
---@return Promise<string[]|nil> Formatted session lines
function M.format_session(session)
  if not session or session == '' then
    return Promise.new():resolve(nil)
  end

  state.last_user_message = nil
  return require('opencode.session').get_messages(session):and_then(function(msgs)
    vim.notify('formatting session', vim.log.levels.WARN)
    state.messages = msgs
    return M._format_messages(session)
  end)
end

---@param session Session Session ID
---@return Output
function M._format_messages(session)
  local output = Output.new()

  output:add_line('')

  for i, msg in ipairs(state.messages) do
    output:add_lines(M.separator)
    state.current_message = msg

    if not state.current_model and msg.info.providerID and msg.info.providerID ~= '' then
      state.current_model = msg.info.providerID .. '/' .. msg.info.modelID
    end

    if msg.info.tokens and msg.info.tokens.input > 0 then
      state.tokens_count = msg.info.tokens.input
        + msg.info.tokens.output
        + msg.info.tokens.cache.read
        + msg.info.tokens.cache.write
    end

    if msg.info.cost and type(msg.info.cost) == 'number' then
      state.cost = msg.info.cost
    end

    if session.revert and session.revert.messageID == msg.info.id then
      ---@type {messages: number, tool_calls: number, files: table<string, {additions: number, deletions: number}>}
      local revert_stats = M._calculate_revert_stats(state.messages, i, session.revert)
      M._format_revert_message(revert_stats, output)
      break
    end

    M._format_message_header(msg.info, i, output)

    for j, part in ipairs(msg.parts or {}) do
      M.format_part_isolated(part, { msg_idx = i, part_idx = j, role = msg.info.role, message = msg }, output)
    end

    if msg.info.error and msg.info.error ~= '' then
      M._format_error(msg.info, output)
    end
  end

  return output
end

function M._handle_permission_request(part, output)
  if part.state and part.state.status == 'error' and part.state.error then
    if part.state.error:match('rejected permission') then
      state.current_permission = nil
    else
      vim.notify('Unknown part state error: ' .. part.state.error)
    end
    return
  end

  M._format_permission_request(output)
end

function M._format_permission_request(output)
  local config_mod = require('opencode.config')
  local keys

  if require('opencode.ui.ui').is_opencode_focused() then
    keys = {
      config.keymap.permission.accept,
      config.keymap.permission.accept_all,
      config.keymap.permission.deny,
    }
  else
    keys = {
      config_mod.get_key_for_function('editor', 'permission_accept'),
      config_mod.get_key_for_function('editor', 'permission_accept_all'),
      config_mod.get_key_for_function('editor', 'permission_deny'),
    }
  end

  output:add_empty_line()
  output:add_line('> [!WARNING] Permission required to run this tool.')
  output:add_line('>')
  output:add_line(('> Accept `%s`    Always `%s`    Deny `%s`'):format(unpack(keys)))
  output:add_empty_line()
end

---@param line number Buffer line number
---@param output Output Output object to query
---@return {message: MessageInfo, part: MessagePart, msg_idx: number, part_idx: number}|nil
function M.get_message_at_line(line, output)
  local metadata = output:get_nearest_metadata(line)
  if metadata and metadata.msg_idx and metadata.part_idx then
    local msg = state.messages and state.messages[metadata.msg_idx]
    if not msg or not msg.parts then
      return nil
    end
    local part = msg.parts[metadata.part_idx]
    if not part then
      return nil
    end
    return {
      message = msg,
      part = part,
      msg_idx = metadata.msg_idx,
      part_idx = metadata.part_idx,
    }
  end
end

---Calculate statistics for reverted messages and tool calls
---@param messages {info: MessageInfo, parts: MessagePart[]}[] All messages in the session
---@param revert_index number Index of the message where revert occurred
---@param revert_info SessionRevertInfo Revert information
---@return {messages: number, tool_calls: number, files: table<string, {additions: number, deletions: number}>}
function M._calculate_revert_stats(messages, revert_index, revert_info)
  local stats = {
    messages = 0,
    tool_calls = 0,
    files = {}, -- { [filename] = { additions = n, deletions = m } }
  }

  for i = revert_index, #messages do
    local msg = messages[i]
    if msg.info.role == 'user' then
      stats.messages = stats.messages + 1
    end
    if msg.parts then
      for _, part in ipairs(msg.parts) do
        if part.type == 'tool' then
          stats.tool_calls = stats.tool_calls + 1
        end
      end
    end
  end

  if revert_info.diff then
    local current_file = nil
    for line in revert_info.diff:gmatch('[^\r\n]+') do
      local file_a = line:match('^%-%-%- ([ab]/.+)')
      local file_b = line:match('^%+%+%+ ([ab]/.+)')
      if file_b then
        current_file = file_b:gsub('^[ab]/', '')
        if not stats.files[current_file] then
          stats.files[current_file] = { additions = 0, deletions = 0 }
        end
      elseif file_a then
        current_file = file_a:gsub('^[ab]/', '')
        if not stats.files[current_file] then
          stats.files[current_file] = { additions = 0, deletions = 0 }
        end
      elseif line:sub(1, 1) == '+' and not line:match('^%+%+%+') then
        if current_file then
          stats.files[current_file].additions = stats.files[current_file].additions + 1
        end
      elseif line:sub(1, 1) == '-' and not line:match('^%-%-%-') then
        if current_file then
          stats.files[current_file].deletions = stats.files[current_file].deletions + 1
        end
      end
    end
  end

  return stats
end

---Format the revert callout with statistics
---@param stats {messages: number, tool_calls: number, files: table<string, {additions: number, deletions: number}>}
---@param output Output Output object to write to
function M._format_revert_message(stats, output)
  local message_text = stats.messages == 1 and 'message' or 'messages'
  local tool_text = stats.tool_calls == 1 and 'tool call' or 'tool calls'

  output:add_line(
    string.format('> %d %s reverted, %d %s reverted', stats.messages, message_text, stats.tool_calls, tool_text)
  )
  output:add_line('>')
  output:add_line('> type `/redo` to restore.')
  output:add_empty_line()

  if stats.files and next(stats.files) then
    for file, fstats in pairs(stats.files) do
      local file_diff = {}
      if fstats.additions > 0 then
        table.insert(file_diff, '+' .. fstats.additions)
      end
      if fstats.deletions > 0 then
        table.insert(file_diff, '-' .. fstats.deletions)
      end
      if #file_diff > 0 then
        local line_str = string.format(icons.get('file') .. '%s: %s', file, table.concat(file_diff, ' '))
        local line_idx = output:add_line(line_str)
        local col = #('  ' .. file .. ': ')
        for _, diff in ipairs(file_diff) do
          local hl_group = diff:sub(1, 1) == '+' and 'OpencodeDiffAddText' or 'OpencodeDiffDeleteText'
          output:add_extmark(line_idx, {
            virt_text = { { diff, hl_group } },
            virt_text_pos = 'inline',
            virt_text_win_col = col,
            priority = 1000,
          })
          col = col + #diff + 1
        end
      end
    end
  end
end

---@param part MessagePart
---@param output Output Output object to write to
function M._format_patch(part, output)
  local restore_points = snapshot.get_restore_points_by_parent(part.hash)
  M._format_action(icons.get('snapshot') .. ' Created Snapshot', vim.trim(part.hash:sub(1, 8)), output)
  local snapshot_header_line = output:get_line_count()

  -- Anchor all snapshot-level actions to the snapshot header line
  output:add_action({
    text = '[R]evert file',
    type = 'diff_revert_selected_file',
    args = { part.hash },
    key = 'R',
    display_line = snapshot_header_line,
    range = { from = snapshot_header_line, to = snapshot_header_line },
  })
  output:add_action({
    text = 'Revert [A]ll',
    type = 'diff_revert_all',
    args = { part.hash },
    key = 'A',
    display_line = snapshot_header_line,
    range = { from = snapshot_header_line, to = snapshot_header_line },
  })
  output:add_action({
    text = '[D]iff',
    type = 'diff_open',
    args = { part.hash },
    key = 'D',
    display_line = snapshot_header_line,
    range = { from = snapshot_header_line, to = snapshot_header_line },
  })

  if #restore_points > 0 then
    for _, restore_point in ipairs(restore_points) do
      output:add_line(
        string.format(
          '  %s Restore point `%s` - %s',
          icons.get('restore_point'),
          restore_point.id:sub(1, 8),
          util.time_ago(restore_point.created_at)
        )
      )
      local restore_line = output:get_line_count()
      output:add_action({
        text = 'Restore [A]ll',
        type = 'diff_restore_snapshot_all',
        args = { part.hash },
        key = 'A',
        display_line = restore_line,
        range = { from = restore_line, to = restore_line },
      })
      output:add_action({
        text = '[R]estore file',
        type = 'diff_restore_snapshot_file',
        args = { part.hash },
        key = 'R',
        display_line = restore_line,
        range = { from = restore_line, to = restore_line },
      })
    end
  end
end

---@param message MessageInfo
---@param output Output Output object to write to
function M._format_error(message, output)
  output:add_empty_line()
  M._format_callout('ERROR', vim.inspect(message.error), output)
end

---@param message MessageInfo
---@param msg_idx number Message index in the session
---@param output Output Output object to write to
function M._format_message_header(message, msg_idx, output)
  local role = message.role or 'unknown'
  local icon = message.role == 'user' and icons.get('header_user') or icons.get('header_assistant')

  local time = message.time and message.time.created or nil
  local time_text = (time and ' (' .. util.time_ago(time) .. ')' or '')
  local role_hl = 'OpencodeMessageRole' .. role:sub(1, 1):upper() .. role:sub(2)
  local model_text = message.modelID and ' ' .. message.modelID or ''
  local debug_text = config.debug and ' [' .. message.id .. ']' or ''

  output:add_empty_line()
  output:add_metadata({ msg_idx = msg_idx, part_idx = 1, role = role, type = 'header' })

  local display_name
  if role == 'assistant' then
    local mode = message.mode
    if mode and mode ~= '' then
      display_name = mode:upper()
    else
      -- For the most recent assistant message, show current_mode if mode is missing
      -- This handles new messages that haven't been stamped yet
      local is_last_message = msg_idx == #state.messages
      if is_last_message and state.current_mode and state.current_mode ~= '' then
        display_name = state.current_mode:upper()
      else
        display_name = 'ASSISTANT'
      end
    end
  else
    display_name = role:upper()
  end

  output:add_extmark(output:get_line_count(), {
    virt_text = {
      { icon, role_hl },
      { ' ' },
      { display_name, role_hl },
      { model_text, 'OpencodeHint' },
      { time_text, 'OpencodeHint' },
      { debug_text, 'OpencodeHint' },
    },
    virt_text_win_col = -3,
    priority = 10,
  })

  output:add_line('')
end

---@param callout string Callout type (e.g., 'ERROR', 'TODO')
---@param text string Callout text content
---@param output Output Output object to write to
---@param title? string Optional title for the callout
function M._format_callout(callout, text, output, title)
  title = title and title .. ' ' or ''
  local win_width = (state.windows and state.windows.output_win and vim.api.nvim_win_is_valid(state.windows.output_win))
      and vim.api.nvim_win_get_width(state.windows.output_win)
    or config.ui.window_width
    or 80
  if #text > win_width - 4 then
    local ok, substituted = pcall(vim.fn.substitute, text, '\v(.{' .. (win_width - 8) .. '})', '\1\n', 'g')
    text = ok and substituted or text
  end

  -- Trim off any trailing newlines so there isn't an extra line in the
  -- extmarks section
  local lines = vim.split(text:gsub('\n$', ''), '\n')
  if #lines == 1 and title == '' then
    output:add_line('> [!' .. callout .. '] ' .. lines[1])
  else
    output:add_line('> [!' .. callout .. ']' .. title)
    output:add_line('>')
    output:add_lines(lines, '> ')
  end
end

---@param text string
---@param output Output Output object to write to
function M._format_user_prompt(text, output)
  local start_line = output:get_line_count()

  output:add_lines(vim.split(text, '\n'))

  local end_line = output:get_line_count()

  M._add_vertical_border(start_line, end_line, 'OpencodeMessageRoleUser', -3, output)
end

---@param part MessagePart
---@param output Output Output object to write to
function M._format_selection_context(part, output)
  local json = context_module.decode_json_context(part.text, 'selection')
  if not json then
    return
  end
  local start_line = output:get_line_count()
  output:add_lines(vim.split(json.content, '\n'))
  output:add_empty_line()

  local end_line = output:get_line_count()

  M._add_vertical_border(start_line, end_line, 'OpencodeMessageRoleUser', -3, output)
end

---Format and display the file path in the context
---@param path string|nil File path
---@param output Output Output object to write to
function M._format_context_file(path, output)
  if not path or path == '' then
    return
  end
  local cwd = vim.fn.getcwd()
  if vim.startswith(path, cwd) then
    path = path:sub(#cwd + 2)
  end
  return output:add_line(string.format('[%s](%s)', path, path))
end

---@param text string
---@param output Output Output object to write to
function M._format_assistant_message(text, output)
  -- output:add_empty_line()
  output:add_lines(vim.split(text, '\n'))
end

---@param type string Tool type (e.g., 'run', 'read', 'edit', etc.)
---@param value string Value associated with the action (e.g., filename, command)
---@param output Output Output object to write to
function M._format_action(type, value, output)
  if not type or not value then
    return
  end

  output:add_line('**' .. type .. '** `' .. value .. '`')
end

---@param input BashToolInput data for the tool
---@param metadata BashToolMetadata Metadata for the tool use
---@param output Output Output object to write to
function M._format_bash_tool(input, metadata, output)
  M._format_action(icons.get('run') .. ' run', input and input.description, output)

  if not config.ui.output.tools.show_output then
    return
  end

  if metadata.output or metadata.command or input.command then
    local command = input.command or metadata.command or ''
    M._format_code(vim.split('> ' .. command .. '\n\n' .. (metadata.output or ''), '\n'), 'bash')
  end
end

---@param tool_type string Tool type (e.g., 'read', 'edit', 'write')
---@param input FileToolInput data for the tool
---@param metadata FileToolMetadata Metadata for the tool use
---@param output Output Output object to write to
function M._format_file_tool(tool_type, input, metadata, output)
  local file_name = input and vim.fn.fnamemodify(input.filePath, ':t') or ''
  local file_type = input and vim.fn.fnamemodify(input.filePath, ':e') or ''
  local tool_action_icons = { read = icons.get('read'), edit = icons.get('edit'), write = icons.get('write') }

  M._format_action(tool_action_icons[tool_type] .. ' ' .. tool_type, file_name, output)

  if not config.ui.output.tools.show_output then
    return
  end

  if tool_type == 'edit' and metadata.diff then
    M._format_diff(metadata.diff, file_type, output)
  elseif tool_type == 'write' and input and input.content then
    M._format_code(vim.split(input.content, '\n'), file_type, output)
  end
end

---@param title string
---@param input TodoToolInput
---@param output Output Output object to write to
function M._format_todo_tool(title, input, output)
  M._format_action(icons.get('plan') .. ' plan', (title or ''), output)
  if not config.ui.output.tools.show_output then
    return
  end

  local todos = input and input.todos or {}

  for _, item in ipairs(todos) do
    local statuses = { in_progress = '-', completed = 'x', pending = ' ' }
    output:add_line(string.format('- [%s] %s ', statuses[item.status], item.content))
  end
end

---@param input GlobToolInput data for the tool
---@param metadata GlobToolMetadata Metadata for the tool use
---@param output Output Output object to write to
function M._format_glob_tool(input, metadata, output)
  M._format_action(icons.get('search') .. ' glob', input and input.pattern, output)
  if not config.ui.output.tools.show_output then
    return
  end
  local prefix = metadata.truncated and ' more than' or ''
  output:add_line(string.format('Found%s `%d` file(s):', prefix, metadata.count or 0))
end

---@param input GrepToolInput data for the tool
---@param metadata GrepToolMetadata Metadata for the tool use
---@param output Output Output object to write to
function M._format_grep_tool(input, metadata, output)
  input = input or { path = '', include = '', pattern = '' }

  local grep_str = string.format('%s` `%s', (input.path or input.include) or '', input.pattern or '')

  M._format_action(icons.get('search') .. ' grep', grep_str, output)
  if not config.ui.output.tools.show_output then
    return
  end
  local prefix = metadata.truncated and ' more than' or ''
  output:add_line(
    string.format('Found%s `%d` match' .. (metadata.matches ~= 1 and 'es' or ''), prefix, metadata.matches or 0)
  )
end

---@param input WebFetchToolInput data for the tool
---@param output Output Output object to write to
function M._format_webfetch_tool(input, output)
  M._format_action(icons.get('web') .. ' fetch', input and input.url, output)
end

---@param input ListToolInput
---@param metadata ListToolMetadata
---@param tool_output string
---@param output Output Output object to write to
function M._format_list_tool(input, metadata, tool_output, output)
  M._format_action(icons.get('list') .. ' list', input and input.path or '', output)
  if not config.ui.output.tools.show_output then
    return
  end
  local lines = vim.split(vim.trim(tool_output or ''), '\n')
  if #lines < 1 or metadata.count == 0 then
    output:add_line('No files found.')
    return
  end
  if #lines > 1 then
    output:add_line('Files:')
    for i = 2, #lines do
      local file = vim.trim(lines[i])
      if file ~= '' then
        output:add_line('  • ' .. file)
      end
    end
  end
  if metadata.truncated then
    output:add_line(string.format('Results truncated, showing first %d files', metadata.count or '?'))
  end
end

---@param part MessagePart
---@param output Output Output object to write to
function M._format_tool(part, output)
  local tool = part.tool
  if not tool or not part.state then
    return
  end

  local start_line = output:get_line_count() + 1
  local input = part.state.input or {}
  local metadata = part.state.metadata or {}
  local tool_output = part.state.output or ''

  if state.current_permission and state.current_permission.messageID == part.messageID then
    metadata = state.current_permission.metadata or metadata
  end

  if tool == 'bash' then
    M._format_bash_tool(input --[[@as BashToolInput]], metadata --[[@as BashToolMetadata]], output)
  elseif tool == 'read' or tool == 'edit' or tool == 'write' then
    M._format_file_tool(tool, input --[[@as FileToolInput]], metadata --[[@as FileToolMetadata]], output)
  elseif tool == 'todowrite' then
    M._format_todo_tool(part.state.title, input --[[@as TodoToolInput]], output)
  elseif tool == 'glob' then
    M._format_glob_tool(input --[[@as GlobToolInput]], metadata --[[@as GlobToolMetadata]], output)
  elseif tool == 'list' then
    M._format_list_tool(input --[[@as ListToolInput]], metadata --[[@as ListToolMetadata]], tool_output, output)
  elseif tool == 'grep' then
    M._format_grep_tool(input --[[@as GrepToolInput]], metadata --[[@as GrepToolMetadata]], output)
  elseif tool == 'webfetch' then
    M._format_webfetch_tool(input --[[@as WebFetchToolInput]], output)
  elseif tool == 'task' then
    M._format_task_tool(input --[[@as TaskToolInput]], metadata --[[@as TaskToolMetadata]], tool_output, output)
  else
    M._format_action(icons.get('tool') .. ' tool', tool, output)
  end

  if part.state.status == 'error' then
    output:add_line('')
    M._format_callout('ERROR', part.state.error, output)
  ---@diagnostic disable-next-line: undefined-field
  elseif part.state.input and part.state.input.error then
    output:add_line('')
    ---I'm not sure about the type with state.input.error
    ---@diagnostic disable-next-line: undefined-field
    M._format_callout('ERROR', part.state.input.error, output)
  end

  if
    state.current_permission
    and state.current_permission.messageID == part.messageID
    and state.current_permission.callID == part.callID
  then
    M._handle_permission_request(part, output)
  end

  local end_line = output:get_line_count()
  if end_line - start_line > 1 then
    M._add_vertical_border(start_line, end_line, 'OpencodeToolBorder', -1, output)
  end
end

---@param input TaskToolInput data for the tool
---@param metadata TaskToolMetadata Metadata for the tool use
---@param tool_output string
---@param output Output Output object to write to
function M._format_task_tool(input, metadata, tool_output, output)
  local start_line = output:get_line_count() + 1
  M._format_action(icons.get('task') .. ' task', input and input.description, output)

  if config.ui.output.tools.show_output then
    if tool_output and tool_output ~= '' then
      output:add_empty_line()
      output:add_lines(vim.split(tool_output, '\n'))
      output:add_empty_line()
    end

    if metadata.summary and type(metadata.summary) == 'table' then
      for _, sub_part in ipairs(metadata.summary) do
        if sub_part.type == 'tool' and sub_part.tool then
          M._format_tool(sub_part, output)
        end
      end
    end
  end

  local end_line = output:get_line_count()
  output:add_action({
    text = '[S]elect Child Session',
    type = 'select_child_session',
    args = {},
    key = 'S',
    display_line = start_line - 1,
    range = { from = start_line, to = end_line },
  })
end

---@param lines string[]
---@param language string
---@param output Output Output object to write to
function M._format_code(lines, language, output)
  output:add_empty_line()
  output:add_line('```' .. (language or ''))
  output:add_lines(lines)
  output:add_line('```')
end

---@param code string
---@param file_type string
---@param output Output Output object to write to
function M._format_diff(code, file_type, output)
  output:add_empty_line()
  output:add_line('```' .. file_type)
  local lines = vim.split(code, '\n')
  if #lines > 5 then
    lines = vim.list_slice(lines, 6)
  end

  for _, line in ipairs(lines) do
    local first_char = line:sub(1, 1)
    if first_char == '+' or first_char == '-' then
      local hl_group = first_char == '+' and 'OpencodeDiffAdd' or 'OpencodeDiffDelete'
      output:add_line(' ' .. line:sub(2))
      local line_idx = output:get_line_count()
      output:add_extmark(line_idx, function()
        return {
          end_col = 0,
          end_row = line_idx,
          virt_text = { { first_char, hl_group } },
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
      output:add_line(line)
    end
  end
  output:add_line('```')
end

---@param start_line number
---@param end_line number
---@param hl_group string
---@param win_col number
---@param output Output Output object to write to
function M._add_vertical_border(start_line, end_line, hl_group, win_col, output)
  for line = start_line, end_line do
    output:add_extmark(line, {
      virt_text = { { require('opencode.ui.icons').get('border'), hl_group } },
      virt_text_pos = 'overlay',
      virt_text_win_col = win_col,
      virt_text_repeat_linebreak = true,
    })
  end
end

---@param part MessagePart
---@param message_info {msg_idx: number, part_idx: number, role: string, message: table}
---@param output? Output Optional output object (creates new if not provided)
---@return Output
function M.format_part_isolated(part, message_info, output)
  local temp_output = output or Output.new()

  local metadata = {
    msg_idx = message_info.msg_idx,
    part_idx = message_info.part_idx,
    role = message_info.role,
    type = part.type,
    snapshot = part.snapshot,
  }
  temp_output:add_metadata(metadata)

  local content_added = false

  if message_info.role == 'user' then
    if part.type == 'text' and part.text then
      if part.synthetic == true then
        M._format_selection_context(part, temp_output)
      else
        M._format_user_prompt(vim.trim(part.text), temp_output)
        content_added = true
      end
    elseif part.type == 'file' then
      local file_line = M._format_context_file(part.filename, temp_output)
      M._add_vertical_border(file_line - 1, file_line, 'OpencodeMessageRoleUser', -3, temp_output)
      content_added = true
    end
  elseif message_info.role == 'assistant' then
    if part.type == 'text' and part.text then
      M._format_assistant_message(vim.trim(part.text), temp_output)
      content_added = true
    elseif part.type == 'tool' then
      M._format_tool(part, temp_output)
      content_added = true
    elseif part.type == 'patch' and part.hash then
      M._format_patch(part, temp_output)
      content_added = true
    end
  end

  if content_added then
    temp_output:add_empty_line()
  end

  return temp_output
end

---@param message OpencodeMessage
---@param msg_idx number
---@return Output
function M.format_message_header_isolated(message, msg_idx)
  local temp_output = Output.new()

  if not state.current_model and message.info.providerID and message.info.providerID ~= '' then
    state.current_model = message.info.providerID .. '/' .. message.info.modelID
  end

  if message.info.tokens and message.info.tokens.input > 0 then
    state.tokens_count = message.info.tokens.input
      + message.info.tokens.output
      + message.info.tokens.cache.read
      + message.info.tokens.cache.write
  end

  if message.info.cost and type(message.info.cost) == 'number' then
    state.cost = message.info.cost
  end

  temp_output:add_lines(M.separator)
  M._format_message_header(message.info, msg_idx, temp_output)

  return temp_output
end

---@param error_text string
---@return Output
function M.format_error_callout(error_text)
  local temp_output = Output.new()

  temp_output:add_empty_line()
  M._format_callout('ERROR', error_text, temp_output)

  return temp_output
end

return M
