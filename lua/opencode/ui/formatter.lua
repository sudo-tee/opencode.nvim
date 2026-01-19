local context_module = require('opencode.context')
local icons = require('opencode.ui.icons')
local util = require('opencode.util')
local Output = require('opencode.ui.output')
local state = require('opencode.state')
local config = require('opencode.config')
local snapshot = require('opencode.snapshot')
local mention = require('opencode.ui.mention')
local permission_window = require('opencode.ui.permission_window')

local M = {}

M.separator = {
  '----',
  '',
}

---@param output Output
---@param part OpencodeMessagePart
function M._format_reasoning(output, part)
  local text = vim.trim(part.text or '')
  if text == '' then
    return
  end

  local start_line = output:get_line_count() + 1

  local title = 'Reasoning'
  local time = part.time
  if time and type(time) == 'table' and time.start then
    local start_text = util.format_time(time.start) or ''
    local end_text = (time['end'] and util.format_time(time['end'])) or nil
    if end_text and end_text ~= '' then
      title = string.format('%s (%s - %s)', title, start_text, end_text)
    elseif start_text ~= '' then
      title = string.format('%s (%s)', title, start_text)
    end
  end

  M.format_action(output, icons.get('reasoning') .. ' ' .. title, '')

  if config.ui.output.tools.show_reasoning_output then
    output:add_empty_line()
    output:add_lines(vim.split(text, '\n'))
    output:add_empty_line()
  end

  local end_line = output:get_line_count()
  if end_line - start_line > 1 then
    M.add_vertical_border(output, start_line, end_line, 'OpencodeToolBorder', -1, 'OpencodeReasoningText')
  else
    output:add_extmark(start_line - 1, {
      line_hl_group = 'OpencodeReasoningText',
    } --[[@as OutputExtmark]])
  end
end

---Calculate statistics for reverted messages and tool calls
---@param messages {info: MessageInfo, parts: OpencodeMessagePart[]}[] All messages in the session
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
---@param session_data OpencodeMessage[] All messages in the session
---@param start_idx number Index of the message where revert occurred
---@return Output output object representing the lines, extmarks, and actions
function M._format_revert_message(session_data, start_idx)
  local output = Output.new()
  local stats = M._calculate_revert_stats(session_data, start_idx, state.active_session.revert)
  local message_text = stats.messages == 1 and 'message' or 'messages'
  local tool_text = stats.tool_calls == 1 and 'tool call' or 'tool calls'

  output:add_lines(M.separator)
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
          output:add_extmark(line_idx - 1, {
            virt_text = { { diff, hl_group } },
            virt_text_pos = 'inline',
            virt_text_win_col = col,
            priority = 1000,
          } --[[@as OutputExtmark]])
          col = col + #diff + 1
        end
      end
    end
  end
  return output
end

local function add_action(output, text, action_type, args, key, line)
  -- actions use api-indexing (e.g. 0 indexed)
  line = (line or output:get_line_count()) - 1
  output:add_action({
    text = text,
    type = action_type,
    args = args,
    key = key,
    display_line = line,
    range = { from = line, to = line },
  })
end

---@param output Output Output object to write to
---@param part OpencodeMessagePart
function M._format_patch(output, part)
  if not part.hash then
    return
  end

  local restore_points = snapshot.get_restore_points_by_parent(part.hash) or {}
  M.format_action(output, icons.get('snapshot') .. ' Created Snapshot', vim.trim(part.hash:sub(1, 8)))

  -- Anchor all snapshot-level actions to the snapshot header line
  add_action(output, '[R]evert file', 'diff_revert_selected_file', { part.hash }, 'R')
  add_action(output, 'Revert [A]ll', 'diff_revert_all', { part.hash }, 'A')
  add_action(output, '[D]iff', 'diff_open', { part.hash }, 'D')

  if #restore_points > 0 then
    for _, restore_point in ipairs(restore_points) do
      output:add_line(
        string.format(
          '  %s Restore point `%s` - %s ',
          icons.get('restore_point'),
          vim.trim(restore_point.id:sub(1, 8)),
          util.format_time(restore_point.created_at)
        )
      )
      add_action(output, 'Restore [A]ll', 'diff_restore_snapshot_all', { restore_point.id }, 'A')
      add_action(output, '[R]estore file', 'diff_restore_snapshot_file', { restore_point.id }, 'R')
    end
  end
end

---@param output Output Output object to write to
---@param message MessageInfo
function M._format_error(output, message)
  output:add_empty_line()
  M._format_callout(output, 'ERROR', vim.inspect(message.error))
end

---@param message OpencodeMessage
---@return Output
function M.format_message_header(message)
  local output = Output.new()

  output:add_lines(M.separator)
  local role = message.info.role or 'unknown'
  local icon = message.info.role == 'user' and icons.get('header_user') or icons.get('header_assistant')

  local time = message.info.time and message.info.time.created or nil
  local time_text = (time and ' (' .. util.format_time(time) .. ')' or '')
  local role_hl = 'OpencodeMessageRole' .. role:sub(1, 1):upper() .. role:sub(2)
  local model_text = message.info.modelID and ' ' .. message.info.modelID or ''

  local debug_text = config.debug.show_ids and ' [' .. message.info.id .. ']' or ''

  local display_name
  if role == 'assistant' then
    local mode = message.info.mode
    if mode and mode ~= '' then
      display_name = mode:upper()
    else
      -- For the most recent assistant message, show current_mode if mode is missing
      -- This handles new messages that haven't been stamped yet
      local is_last_message = #state.messages == 0 or message.info.id == state.messages[#state.messages].info.id
      if is_last_message and state.current_mode and state.current_mode ~= '' then
        display_name = state.current_mode:upper()
      else
        display_name = 'ASSISTANT'
      end
    end
  else
    display_name = role:upper()
  end

  output:add_extmark(output:get_line_count() - 1, {
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
  } --[[@as OutputExtmark]])

  -- Only want to show the error if we have no parts. If we have parts, they'll
  -- handle rendering the error
  if
    role == 'assistant'
    and message.info.error
    and message.info.error ~= ''
    and (not message.parts or #message.parts == 0)
  then
    local error = message.info.error
    local error_message = error.data and error.data.message or vim.inspect(error)

    output:add_line('')
    M._format_callout(output, 'ERROR', error_message)
  end

  output:add_line('')
  return output
end

---@param output Output Output object to write to
---@param callout string Callout type (e.g., 'ERROR', 'TODO')
---@param text string Callout text content
---@param title? string Optional title for the callout
function M._format_callout(output, callout, text, title)
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

---@param output Output Output object to write to
---@param text string
---@param message? OpencodeMessage Optional message object to extract mentions from
function M._format_user_prompt(output, text, message)
  local start_line = output:get_line_count()

  output:add_lines(vim.split(text, '\n'))

  local end_line = output:get_line_count()

  local end_line_extmark_offset = 0

  local mentions = {}
  if message and message.parts then
    -- message.parts will only be filled out on a re-render
    -- we need to collect the mentions here
    for _, part in ipairs(message.parts) do
      if part.type == 'file' then
        -- we're rerendering this part and we have files, the space after the user prompt
        -- also needs an extmark
        end_line_extmark_offset = 1
        if part.source and part.source.text then
          table.insert(mentions, part.source.text)
        end
      elseif part.type == 'agent' then
        if part.source then
          table.insert(mentions, part.source)
        end
      end
    end
  end

  if #mentions > 0 then
    mention.highlight_mentions_in_output(output, text, mentions, start_line)
  end

  M.add_vertical_border(output, start_line, end_line + end_line_extmark_offset, 'OpencodeMessageRoleUser', -3)
end

---@param output Output Output object to write to
---@param part OpencodeMessagePart
function M._format_selection_context(output, part)
  local json = context_module.decode_json_context(part.text or '', 'selection')
  if not json then
    return
  end
  local start_line = output:get_line_count()
  output:add_lines(vim.split(json.content or '', '\n'))
  output:add_empty_line()

  local end_line = output:get_line_count()

  M.add_vertical_border(output, start_line, end_line, 'OpencodeMessageRoleUser', -3)
end

---@param output Output Output object to write to
---@param part OpencodeMessagePart
function M._format_cursor_data_context(output, part)
  local json = context_module.decode_json_context(part.text or '', 'cursor-data')
  if not json then
    return
  end
  local start_line = output:get_line_count()
  output:add_line('Line ' .. json.line .. ':')
  output:add_lines(vim.split(json.line_content or '', '\n'))
  output:add_empty_line()

  local end_line = output:get_line_count()

  M.add_vertical_border(output, start_line, end_line, 'OpencodeMessageRoleUser', -3)
end

---@param output Output Output object to write to
---@param part OpencodeMessagePart
function M._format_diagnostics_context(output, part)
  local json = context_module.decode_json_context(part.text or '', 'diagnostics')
  if not json then
    return
  end
  local start_line = output:get_line_count()
  local diagnostics = json.content --[[@as OpencodeDiagnostic[] ]]
  if not diagnostics or type(diagnostics) ~= 'table' or #diagnostics == 0 then
    return
  end

  local diagnostics_count = { error = 0, warn = 0, info = 0 }
  local diagnostics_icons = {
    error = icons.get('error'),
    warn = icons.get('warning'),
    info = icons.get('info'),
  }

  for _, diag in ipairs(diagnostics) do
    local name = vim.diagnostic.severity[diag.severity]:lower()
    diagnostics_count[name] = diagnostics_count[name] + 1
  end

  local diag_line = '**Diagnostics:**'
  for name, count in pairs(diagnostics_count) do
    if count > 0 then
      diag_line = diag_line .. (string.format(' %s(%d)', diagnostics_icons[name], count))
    end
  end
  output:add_line(diag_line)
  output:add_empty_line()
  local end_line = output:get_line_count()

  M.add_vertical_border(output, start_line, end_line, 'OpencodeMessageRoleUser', -3)
end

---Format and display the file path in the context
---@param output Output Output object to write to
---@param path string|nil File path
function M._format_context_file(output, path)
  if not path or path == '' then
    return
  end
  local cwd = vim.fn.getcwd()
  if vim.startswith(path, cwd) then
    path = path:sub(#cwd + 2)
  end
  return output:add_line(string.format('[%s](%s)', path, path))
end

---@param output Output Output object to write to
---@param text string
function M._format_assistant_message(output, text)
  local reference_picker = require('opencode.ui.reference_picker')
  local references = reference_picker.parse_references(text, '')

  -- If no references, just add the text as-is
  if #references == 0 then
    output:add_lines(vim.split(text, '\n'))
    return
  end

  -- Sort references by match_start position (ascending)
  table.sort(references, function(a, b)
    return a.match_start < b.match_start
  end)

  -- Build a new text with icons inserted before each reference
  local result = ''
  local last_pos = 1
  local ref_icon = icons.get('reference')

  for _, ref in ipairs(references) do
    -- Add text before this reference
    result = result .. text:sub(last_pos, ref.match_start - 1)
    -- Add the icon and the reference
    result = result .. ref_icon .. text:sub(ref.match_start, ref.match_end)
    last_pos = ref.match_end + 1
  end

  -- Add any remaining text after the last reference
  if last_pos <= #text then
    result = result .. text:sub(last_pos)
  end

  output:add_lines(vim.split(result, '\n'))
end

---@param output Output Output object to write to
---@param tool_type string Tool type (e.g., 'run', 'read', 'edit', etc.)
---@param value string Value associated with the action (e.g., filename, command)
function M.format_action(output, tool_type, value)
  if not tool_type or not value then
    return
  end
  local line = string.format('**%s** %s', tool_type, value and #value > 0 and ('`' .. value .. '`') or '')

  output:add_line(line)
end

---@param output Output Output object to write to
---@param input BashToolInput data for the tool
---@param metadata BashToolMetadata Metadata for the tool use
function M._format_bash_tool(output, input, metadata)
  M.format_action(output, icons.get('run') .. ' run', input and input.description)

  if not config.ui.output.tools.show_output then
    return
  end

  if metadata.output or metadata.command or input.command then
    local command = input.command or metadata.command or ''
    local command_output = metadata.output and metadata.output ~= '' and ('\n' .. metadata.output) or ''
    M._format_code(output, vim.split('> ' .. command .. '\n' .. command_output, '\n'), 'bash')
  end
end

---@param output Output Output object to write to
---@param tool_type string Tool type (e.g., 'read', 'edit', 'write')
---@param input FileToolInput data for the tool
---@param metadata FileToolMetadata Metadata for the tool use
function M._format_file_tool(output, tool_type, input, metadata)
  local file_name = input and vim.fn.fnamemodify(input.filePath, ':t') or ''
  local file_type = input and util.get_markdown_filetype(input.filePath) or ''
  local tool_action_icons = { read = icons.get('read'), edit = icons.get('edit'), write = icons.get('write') }

  M.format_action(output, tool_action_icons[tool_type] .. ' ' .. tool_type, file_name)

  if not config.ui.output.tools.show_output then
    return
  end

  if tool_type == 'edit' and metadata.diff then
    M.format_diff(output, metadata.diff, file_type)
  elseif tool_type == 'write' and input and input.content then
    M._format_code(output, vim.split(input.content, '\n'), file_type)
  end
end

---@param output Output Output object to write to
---@param title string
---@param input TodoToolInput
function M._format_todo_tool(output, title, input)
  M.format_action(output, icons.get('plan') .. ' plan', (title or ''))
  if not config.ui.output.tools.show_output then
    return
  end

  local todos = input and input.todos or {}

  for _, item in ipairs(todos) do
    local statuses = { in_progress = '-', completed = 'x', pending = ' ' }
    output:add_line(string.format('- [%s] %s ', statuses[item.status], item.content))
  end
end

---@param output Output Output object to write to
---@param input GlobToolInput data for the tool
---@param metadata GlobToolMetadata Metadata for the tool use
function M._format_glob_tool(output, input, metadata)
  M.format_action(output, icons.get('search') .. ' glob', input and input.pattern)
  if not config.ui.output.tools.show_output then
    return
  end
  local prefix = metadata.truncated and ' more than' or ''
  output:add_line(string.format('Found%s `%d` file(s):', prefix, metadata.count or 0))
end

---@param output Output Output object to write to
---@param input GrepToolInput data for the tool
---@param metadata GrepToolMetadata Metadata for the tool use
function M._format_grep_tool(output, input, metadata)
  input = input or { path = '', include = '', pattern = '' }

  local grep_str = string.format('%s` `%s', (input.path or input.include) or '', input.pattern or '')

  M.format_action(output, icons.get('search') .. ' grep', grep_str)
  if not config.ui.output.tools.show_output then
    return
  end
  local prefix = metadata.truncated and ' more than' or ''
  output:add_line(
    string.format('Found%s `%d` match' .. (metadata.matches ~= 1 and 'es' or ''), prefix, metadata.matches or 0)
  )
end

---@param output Output Output object to write to
---@param input WebFetchToolInput data for the tool
function M._format_webfetch_tool(output, input)
  M.format_action(output, icons.get('web') .. ' fetch', input and input.url)
end

---@param output Output Output object to write to
---@param input ListToolInput
---@param metadata ListToolMetadata
---@param tool_output string
function M._format_list_tool(output, input, metadata, tool_output)
  M.format_action(output, icons.get('list') .. ' list', input and input.path or '')
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

---@param output Output Output object to write to
---@param part OpencodeMessagePart
function M._format_tool(output, part)
  local tool = part.tool
  if not tool or not part.state then
    return
  end

  local start_line = output:get_line_count() + 1
  local input = part.state.input or {}
  local metadata = part.state.metadata or {}
  local tool_output = part.state.output or ''

  if tool == 'bash' then
    M._format_bash_tool(output, input --[[@as BashToolInput]], metadata --[[@as BashToolMetadata]])
  elseif tool == 'read' or tool == 'edit' or tool == 'write' then
    M._format_file_tool(output, tool, input --[[@as FileToolInput]], metadata --[[@as FileToolMetadata]])
  elseif tool == 'todowrite' then
    M._format_todo_tool(output, part.state.title, input --[[@as TodoToolInput]])
  elseif tool == 'glob' then
    M._format_glob_tool(output, input --[[@as GlobToolInput]], metadata --[[@as GlobToolMetadata]])
  elseif tool == 'list' then
    M._format_list_tool(output, input --[[@as ListToolInput]], metadata --[[@as ListToolMetadata]], tool_output)
  elseif tool == 'grep' then
    M._format_grep_tool(output, input --[[@as GrepToolInput]], metadata --[[@as GrepToolMetadata]])
  elseif tool == 'webfetch' then
    M._format_webfetch_tool(output, input --[[@as WebFetchToolInput]])
  elseif tool == 'task' then
    M._format_task_tool(output, input --[[@as TaskToolInput]], metadata --[[@as TaskToolMetadata]], tool_output)
  else
    M.format_action(output, icons.get('tool') .. ' tool', tool)
  end

  if part.state.status == 'error' and part.state.error then
    output:add_line('')
    M._format_callout(output, 'ERROR', part.state.error)
  ---@diagnostic disable-next-line: undefined-field
  elseif part.state.input and part.state.input.error then
    output:add_line('')
    ---I'm not sure about the type with state.input.error
    ---@diagnostic disable-next-line: undefined-field
    M._format_callout(output, 'ERROR', part.state.input.error)
  end

  local end_line = output:get_line_count()
  if end_line - start_line > 1 then
    M.add_vertical_border(output, start_line, end_line, 'OpencodeToolBorder', -1)
  end
end

---@param output Output Output object to write to
---@param input TaskToolInput data for the tool
---@param metadata TaskToolMetadata Metadata for the tool use
---@param tool_output string
function M._format_task_tool(output, input, metadata, tool_output)
  local start_line = output:get_line_count() + 1

  -- Show agent type if available
  local description = input and input.description or ''
  local agent_type = input and input.subagent_type
  if agent_type then
    description = string.format('%s (@%s)', description, agent_type)
  end

  M.format_action(output, icons.get('task') .. ' task', description)

  if config.ui.output.tools.show_output then
    -- Show task summary from metadata
    -- The summary contains items with structure: {id, tool, state: {status, title}}
    if metadata and metadata.summary and type(metadata.summary) == 'table' and #metadata.summary > 0 then
      output:add_empty_line()

      local status_icons = {
        completed = icons.get('status_on') or '+',
        running = icons.get('run') or '>',
        pending = icons.get('status_off') or '-',
        error = icons.get('error') or 'x',
      }

      for _, item in ipairs(metadata.summary) do
        if item.tool then
          local status = item.state and item.state.status or 'pending'
          local title = item.state and item.state.title or item.tool
          local icon = status_icons[status] or status_icons.pending

          output:add_line(string.format('  %s %s', icon, title))
        end
      end

      output:add_empty_line()
    end

    -- Show tool output text (usually the final summary from the subagent)
    if tool_output and tool_output ~= '' then
      -- Strip task_metadata tags from output for cleaner display
      local clean_output = tool_output:gsub('<task_metadata>.-</task_metadata>', ''):gsub('%s+$', '')
      if clean_output ~= '' then
        output:add_empty_line()
        output:add_lines(vim.split(clean_output, '\n'))
        output:add_empty_line()
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

---@param output Output Output object to write to
---@param lines string[]
---@param language string
function M._format_code(output, lines, language)
  output:add_empty_line()
  --- NOTE: use longer code fence because lines could contain ```
  output:add_line('`````' .. (language or ''))
  output:add_lines(util.sanitize_lines(lines))
  output:add_line('`````')
end

---@param output Output Output object to write to
---@param code string
---@param file_type string
function M.format_diff(output, code, file_type)
  output:add_empty_line()

  --- NOTE: use longer code fence because code could contain ```
  output:add_line('`````' .. file_type)
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
      output:add_extmark(line_idx - 1, function()
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
  output:add_line('`````')
end

---@param output Output Output object to write to
---@param start_line number
---@param end_line number
---@param hl_group string Highlight group for the border character
---@param win_col number
---@param text_hl_group? string Optional highlight group for the background/foreground of text lines
function M.add_vertical_border(output, start_line, end_line, hl_group, win_col, text_hl_group)
  for line = start_line, end_line do
    local extmark_opts = {
      virt_text = { { require('opencode.ui.icons').get('border'), hl_group } },
      virt_text_pos = 'overlay',
      virt_text_win_col = win_col,
      virt_text_repeat_linebreak = true,
    }

    -- Add line highlight if text_hl_group is provided
    if text_hl_group then
      extmark_opts.line_hl_group = text_hl_group
    end

    output:add_extmark(line - 1, extmark_opts --[[@as OutputExtmark]])
  end
end

---Formats a single message part and returns the resulting output object
---@param part OpencodeMessagePart The part to format
---@param message? OpencodeMessage Optional message object to extract role and mentions from
---@param is_last_part? boolean Whether this is the last part in the message, used to show an error if there is one
---@return Output
function M.format_part(part, message, is_last_part)
  local output = Output.new()

  if not message or not message.info or not message.info.role then
    return output
  end

  local content_added = false
  local role = message.info.role

  if role == 'user' then
    if part.type == 'text' and part.text then
      if part.synthetic == true then
        M._format_selection_context(output, part)
        M._format_cursor_data_context(output, part)
        M._format_diagnostics_context(output, part)
      else
        M._format_user_prompt(output, vim.trim(part.text), message)
        content_added = true
      end
    elseif part.type == 'file' then
      local file_line = M._format_context_file(output, part.filename)
      if file_line then
        M.add_vertical_border(output, file_line - 1, file_line, 'OpencodeMessageRoleUser', -3)
        content_added = true
      end
    end
  elseif role == 'assistant' then
    if part.type == 'text' and part.text then
      M._format_assistant_message(output, vim.trim(part.text))
      content_added = true
    elseif part.type == 'reasoning' and part.text then
      M._format_reasoning(output, part)
      content_added = true
    elseif part.type == 'tool' then
      M._format_tool(output, part)
      content_added = true
    elseif part.type == 'patch' and part.hash then
      M._format_patch(output, part)
      content_added = true
    end
  elseif role == 'system' then
    if part.type == 'permissions-display' then
      permission_window.format_display(output)
      content_added = true
    end
  end

  if content_added then
    output:add_empty_line()
  end

  if is_last_part and role == 'assistant' and message.info.error and message.info.error ~= '' then
    local error = message.info.error
    local error_message = error.data and error.data.message or vim.inspect(error)
    M._format_callout(output, 'ERROR', error_message)
    output:add_empty_line()
  end

  return output
end

return M
