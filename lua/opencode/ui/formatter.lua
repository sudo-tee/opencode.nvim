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

---@note child-session parts are requested from the renderer at format time

M.separator = {
  '----',
  '',
}

---@param output Output
---@param part OpencodeMessagePart
function M._format_reasoning(output, part)
  local text = vim.trim(part.text or '')

  local start_line = output:get_line_count() + 1

  local title = 'Reasoning'
  local time = part.time
  if time and type(time) == 'table' and time.start then
    local duration_text = util.format_duration_seconds(time.start, time['end'])
    if duration_text then
      title = string.format('%s %s', title, duration_text)
    end
  end

  M.format_action(output, 'reasoning', title, '')

  if config.ui.output.tools.show_reasoning_output and text ~= '' then
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
  M.format_action(output, 'snapshot', 'Created Snapshot', vim.trim(part.hash:sub(1, 8)))

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
      { debug_text, 'OpencodeHint' },
    },
    virt_text_win_col = -3,
    priority = 10,
  } --[[@as OutputExtmark]])

  if time then
    output:add_extmark(output:get_line_count() - 1, {
      virt_text = { { ' ' .. util.format_time(time), 'OpencodeHint' } },
      virt_text_pos = 'right_align',
      priority = 9,
    } --[[@as OutputExtmark]])
  end

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
  return output:add_line(string.format('[`%s`](%s)', path, path))
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

---Build the formatted action line string without writing to output
---@param icon_name string Name of the icon to fetch with `icons.get`
---@param tool_type string Tool type (e.g., 'run', 'read', 'edit', etc.)
---@param value string Value associated with the action (e.g., filename, command)
---@param duration_text? string
---@return string
function M._build_action_line(icon_name, tool_type, value, duration_text)
  local icon = icons.get(icon_name)
  local detail = value and #value > 0 and ('`' .. value .. '`') or ''
  local duration_suffix = duration_text and (' ' .. duration_text) or ''
  return string.format('**%s %s** %s%s', icon, tool_type, detail, duration_suffix)
end

---@param output Output Output object to write to
---@param tool_type string Tool type (e.g., 'run', 'read', 'edit', etc.)
---@param value string Value associated with the action (e.g., filename, command)
---@param duration_text? string
function M.format_action(output, icon_name, tool_type, value, duration_text)
  if not icon_name or not tool_type then
    return
  end
  output:add_line(M._build_action_line(icon_name, tool_type, value, duration_text))
end

---@param output Output Output object to write to
---@param input BashToolInput data for the tool
---@param metadata BashToolMetadata Metadata for the tool use
---@param duration_text? string
function M._format_bash_tool(output, input, metadata, duration_text)
  M.format_action(output, 'run', 'run', input and input.description, duration_text)

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
---@param tool_output? string Tool output payload for detecting directory reads
---@param duration_text? string
function M._format_file_tool(output, tool_type, input, metadata, tool_output, duration_text)
  local file_name = tool_type == 'read' and M._resolve_display_file_name(input and input.filePath or '', tool_output)
    or M._resolve_file_name(input and input.filePath or '')

  local file_type = input and util.get_markdown_filetype(input.filePath) or ''

  M.format_action(output, tool_type, tool_type, file_name, duration_text)

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
---@param metadata ApplyPatchToolMetadata Metadata for the tool use
---@param duration_text? string
function M._format_apply_patch_tool(output, metadata, duration_text)
  for _, file in ipairs(metadata.files or {}) do
    M.format_action(output, 'edit', 'apply patch', file.relativePath or file.filePath, duration_text)
    if config.ui.output.tools.show_output and file.diff then
      local file_type = file and util.get_markdown_filetype(file.filePath) or ''
      M.format_diff(output, file.diff, file_type)
    end
  end
end

---@param output Output Output object to write to
---@param title string
---@param input TodoToolInput
---@param duration_text? string
function M._format_todo_tool(output, title, input, duration_text)
  M.format_action(output, 'plan', 'plan', (title or ''), duration_text)
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
---@param duration_text? string
function M._format_glob_tool(output, input, metadata, duration_text)
  M.format_action(output, 'search', 'glob', input and input.pattern, duration_text)
  if not config.ui.output.tools.show_output then
    return
  end
  local prefix = metadata.truncated and ' more than' or ''
  output:add_line(string.format('Found%s `%d` file(s):', prefix, metadata.count or 0))
end

---@param output Output Output object to write to
---@param input GrepToolInput data for the tool
---@param metadata GrepToolMetadata Metadata for the tool use
---@param duration_text? string
function M._format_grep_tool(output, input, metadata, duration_text)
  local grep_str = M._resolve_grep_string(input)
  M.format_action(output, 'search', 'grep', grep_str, duration_text)
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
---@param duration_text? string
function M._format_webfetch_tool(output, input, duration_text)
  M.format_action(output, 'web', 'fetch', input and input.url, duration_text)
end

---@param output Output Output object to write to
---@param input ListToolInput
---@param metadata ListToolMetadata
---@param tool_output string
---@param duration_text? string
function M._format_list_tool(output, input, metadata, tool_output, duration_text)
  M.format_action(output, 'list', 'list', input and input.path or '', duration_text)
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
---@param input QuestionToolInput Question tool input data
---@param metadata QuestionToolMetadata Question tool metadata
---@param status string Status of the tool execution
---@param duration_text? string
function M._format_question_tool(output, input, metadata, status, duration_text)
  M.format_action(output, 'question', 'question', '', duration_text)
  output:add_empty_line()
  if not config.ui.output.tools.show_output or status ~= 'completed' then
    return
  end

  local questions = input and input.questions or {}
  local answers = metadata and metadata.answers or {}

  for i, question in ipairs(questions) do
    local question_lines = vim.split(question.question, '\n')
    if #question_lines > 1 then
      output:add_line(string.format('**Q%d:** %s', i, question.header))
      for _, line in ipairs(question_lines) do
        output:add_line(line)
      end
    else
      output:add_line(string.format('**Q%d:** %s', i, question_lines[1]))
    end
    local answer = answers[i] and answers[i][1] or 'No answer'
    local answer_lines = vim.split(answer, '\n', { plain = true })

    output:add_line(string.format('**A%d:** %s', i, answer_lines[1]))
    for line_idx = 2, #answer_lines do
      output:add_line(answer_lines[line_idx])
    end

    if i < #questions then
      output:add_line('')
    end
  end
end

function M._resolve_file_name(file_path)
  if not file_path or file_path == '' then
    return ''
  end
  local cwd = vim.fn.getcwd()
  local absolute = vim.fn.fnamemodify(file_path, ':p')
  if vim.startswith(absolute, cwd .. '/') then
    return absolute:sub(#cwd + 2)
  end
  return absolute
end

---@param file_path string
---@param tool_output? string
---@return boolean
function M._is_directory_path(file_path, tool_output)
  if not file_path or file_path == '' then
    return false
  end

  if vim.endswith(file_path, '/') then
    return true
  end

  return type(tool_output) == 'string' and tool_output:match('<type>directory</type>') ~= nil
end

---@param file_path string
---@param tool_output? string
---@return string
function M._resolve_display_file_name(file_path, tool_output)
  local resolved = M._resolve_file_name(file_path)

  if resolved ~= '' and M._is_directory_path(file_path, tool_output) and not vim.endswith(resolved, '/') then
    resolved = resolved .. '/'
  end

  return resolved
end

function M._resolve_grep_string(input)
  if not input then
    return ''
  end
  local path_part = input.path or input.include or ''
  local pattern_part = input.pattern or ''
  return table.concat(
    vim.tbl_filter(function(p)
      return p ~= nil and p ~= ''
    end, { path_part, pattern_part }),
    ' '
  )
end

---@param output Output Output object to write to
---@param part OpencodeMessagePart
---@param get_child_parts? fun(session_id: string): OpencodeMessagePart[]?
function M._format_tool(output, part, get_child_parts)
  local tool = part.tool
  if not tool or not part.state then
    return
  end

  local start_line = output:get_line_count() + 1
  local input = part.state.input or {}
  local metadata = part.state.metadata or {}
  local tool_output = part.state.output or ''
  local tool_time = part.state.time or {}
  local tool_status = part.state.status
  local should_show_duration = tool ~= 'question' and tool_status ~= 'pending'
  local duration_text = should_show_duration and util.format_duration_seconds(tool_time.start, tool_time['end']) or nil

  if tool == 'bash' then
    M._format_bash_tool(output, input --[[@as BashToolInput]], metadata --[[@as BashToolMetadata]], duration_text)
  elseif tool == 'read' or tool == 'edit' or tool == 'write' then
    M._format_file_tool(
      output,
      tool,
      input --[[@as FileToolInput]],
      metadata --[[@as FileToolMetadata]],
      tool_output,
      duration_text
    )
  elseif tool == 'todowrite' then
    M._format_todo_tool(output, part.state.title, input --[[@as TodoToolInput]], duration_text)
  elseif tool == 'glob' then
    M._format_glob_tool(output, input --[[@as GlobToolInput]], metadata --[[@as GlobToolMetadata]], duration_text)
  elseif tool == 'apply_patch' then
    M._format_apply_patch_tool(output, metadata --[[@as ApplyPatchToolMetadata]], duration_text)
  elseif tool == 'list' then
    M._format_list_tool(
      output,
      input --[[@as ListToolInput]],
      metadata --[[@as ListToolMetadata]],
      tool_output,
      duration_text
    )
  elseif tool == 'grep' then
    M._format_grep_tool(output, input --[[@as GrepToolInput]], metadata --[[@as GrepToolMetadata]], duration_text)
  elseif tool == 'webfetch' then
    M._format_webfetch_tool(output, input --[[@as WebFetchToolInput]], duration_text)
  elseif tool == 'task' then
    M._format_task_tool(
      output,
      input --[[@as TaskToolInput]],
      metadata --[[@as TaskToolMetadata]],
      tool_output,
      duration_text,
      get_child_parts
    )
  elseif tool == 'question' then
    M._format_question_tool(
      output,
      input --[[@as QuestionToolInput]],
      metadata --[[@as QuestionToolMetadata]],
      part.state.status,
      duration_text
    )
  else
    M.format_action(output, 'tool', 'tool', tool, duration_text)
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

local tool_summary_handlers = {
  bash = function(_, input)
    return 'run', 'run', input.description or ''
  end,
  read = function(part, input)
    local tool_output = part.state and part.state.output or nil
    return 'read', 'read', M._resolve_display_file_name(input.filePath, tool_output)
  end,
  edit = function(_, input)
    return 'edit', 'edit', M._resolve_file_name(input.filePath)
  end,
  write = function(_, input)
    return 'write', 'write', M._resolve_file_name(input.filePath)
  end,
  apply_patch = function(_, metadata)
    local file = metadata.files and metadata.files[1]
    local others_count = metadata.files and #metadata.files - 1 or 0
    local suffix = others_count > 0 and string.format(' (+%d more)', others_count) or ''

    return 'edit', 'apply patch', file and M._resolve_file_name(file.filePath) .. suffix or ''
  end,
  todowrite = function(part, _)
    return 'plan', 'plan', part.state and part.state.title or ''
  end,
  glob = function(_, input)
    return 'search', 'glob', input.pattern or ''
  end,
  webfetch = function(_, input)
    return 'web', 'fetch', input.url or ''
  end,
  list = function(_, input)
    return 'list', 'list', input.path or ''
  end,
  task = function(_, input)
    return 'task', 'task', input.description or ''
  end,
  grep = function(_, input)
    return 'search', 'grep', M._resolve_grep_string(input)
  end,
  tool = function(_, input)
    return 'tool', 'tool', input.description or ''
  end,
}

---Build the action line string for a part (icon + meaningful value, no duration)
---Used to show per-tool icon+label in child session activity lists.
---@param part OpencodeMessagePart
---@param status string icon name to use for the status (e.g., 'running', 'completed', 'error'). If not provided, will use the default icon for the tool.
---@return string
function M._tool_action_line(part, status)
  local tool = part.tool
  local input = part.state and part.state.input or {}
  local handler = tool_summary_handlers[tool] or tool_summary_handlers['tool']
  local icon_name, tool_label, tool_value = handler(part, input)
  if status ~= 'completed' then
    icon_name = status
  end

  return M._build_action_line(icon_name, tool_label or tool or 'tool', tool_value)
end

---@param output Output Output object to write to
---@param input TaskToolInput data for the tool
---@param metadata TaskToolMetadata Metadata for the tool use
---@param tool_output string
---@param duration_text? string
---@param get_child_parts? fun(session_id: string): OpencodeMessagePart[]?
function M._format_task_tool(output, input, metadata, tool_output, duration_text, get_child_parts)
  local start_line = output:get_line_count() + 1

  -- Show agent type if available
  local description = input and input.description or ''
  local agent_type = input and input.subagent_type
  if agent_type then
    description = string.format('%s (@%s)', description, agent_type)
  end

  M.format_action(output, 'task', 'task', description, duration_text)

  if config.ui.output.tools.show_output then
    -- Show live tool activity from the child session
    local child_session_id = metadata and metadata.sessionId
    local child_parts = child_session_id and get_child_parts and get_child_parts(child_session_id)

    if child_parts and #child_parts > 0 then
      output:add_empty_line()

      for _, item in ipairs(child_parts) do
        if item.tool then
          local status = item.state and item.state.status or 'pending'
          output:add_line(' ' .. M._tool_action_line(item, status))
        end
      end

      output:add_empty_line()
    end

    -- Show tool output text (usually the final summary from the subagent)
    if tool_output and tool_output ~= '' then
      -- remove the task_result tag, only get the inner content, since the tool output is already visually separated and the tag doesn't add much value in that case
      local clean_output = tool_output:gsub('<task_result>', ''):gsub('</task_result>', '')
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

---@param lines string[]
local function parse_diff_line_numbers(lines)
  local numbered_lines = {}
  local old_line
  local new_line
  local max_line_number = 0

  for idx, line in ipairs(lines) do
    local old_start, new_start = line:match('^@@ %-(%d+),?%d* %+(%d+),?%d* @@')

    if old_start and new_start then
      old_line = tonumber(old_start)
      new_line = tonumber(new_start)
    elseif old_line and new_line then
      local first_char = line:sub(1, 1)

      if first_char == ' ' then
        numbered_lines[idx] = { old = old_line, new = new_line }
        max_line_number = math.max(max_line_number, old_line, new_line)
        old_line = old_line + 1
        new_line = new_line + 1
      elseif first_char == '+' and not line:match('^%+%+%+%s') then
        numbered_lines[idx] = { old = nil, new = new_line }
        max_line_number = math.max(max_line_number, new_line)
        new_line = new_line + 1
      elseif first_char == '-' and not line:match('^%-%-%-%s') then
        numbered_lines[idx] = { old = old_line, new = nil }
        max_line_number = math.max(max_line_number, old_line)
        old_line = old_line + 1
      end
    end
  end

  return numbered_lines, #tostring(max_line_number)
end

local function build_diff_gutter(line_numbers, width)
  local line_number = line_numbers.new or line_numbers.old
  return string.format('%-' .. width .. 's', line_number and tostring(line_number) or '')
end

local function add_diff_line(output, line, line_numbers, width)
  local first_char = line:sub(1, 1)
  local line_hl = first_char == '+' and 'OpencodeDiffAdd' or first_char == '-' and 'OpencodeDiffDelete' or nil
  local gutter_hl = first_char == '+' and 'OpencodeDiffAddGutter'
    or first_char == '-' and 'OpencodeDiffDeleteGutter'
    or 'OpencodeDiffGutter'
  local sign_hl = gutter_hl
  local gutter = build_diff_gutter(line_numbers, width)
  local gutter_width = #gutter + 2

  output:add_line(string.rep(' ', gutter_width) .. line:sub(2))

  local line_idx = output:get_line_count()
  local extmark = {
    end_col = 0,
    end_row = line_idx,
    virt_text = {
      { gutter, gutter_hl },
      { first_char, sign_hl },
      { ' ', gutter_hl },
    },
    priority = 5000,
    right_gravity = true,
    end_right_gravity = false,
    virt_text_hide = false,
    virt_text_pos = 'overlay',
    virt_text_repeat_linebreak = false,
  }

  if line_hl then
    extmark.hl_group = line_hl
    extmark.hl_eol = true
  end

  output:add_extmark(line_idx - 1, extmark --[[@as OutputExtmark]])
end

function M.format_diff(output, code, file_type)
  output:add_empty_line()

  --- NOTE: use longer code fence because code could contain ```
  output:add_line('`````' .. file_type)
  local full_lines = vim.split(code, '\n')
  local numbered_lines, line_number_width = parse_diff_line_numbers(full_lines)
  local first_visible_line = #full_lines > 5 and 6 or 1
  local lines = first_visible_line > 1 and vim.list_slice(full_lines, first_visible_line) or full_lines

  for idx, line in ipairs(lines) do
    local source_idx = first_visible_line + idx - 1
    if numbered_lines[source_idx] then
      add_diff_line(output, line, numbered_lines[source_idx], line_number_width)
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
---@param get_child_parts? fun(session_id: string): OpencodeMessagePart[]?
---@return Output
function M.format_part(part, message, is_last_part, get_child_parts)
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
    elseif part.type == 'reasoning' then
      M._format_reasoning(output, part)
      content_added = true
    elseif part.type == 'tool' then
      M._format_tool(output, part, get_child_parts)
      content_added = true
    elseif part.type == 'patch' and part.hash then
      M._format_patch(output, part)
      content_added = true
    end
  elseif role == 'system' then
    if part.type == 'permissions-display' then
      permission_window.format_display(output)
      content_added = true
    elseif part.type == 'questions-display' then
      local question_window = require('opencode.ui.question_window')
      question_window.format_display(output)
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
