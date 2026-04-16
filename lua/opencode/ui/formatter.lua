local context_module = require('opencode.context')
local icons = require('opencode.ui.icons')
local util = require('opencode.util')
local Output = require('opencode.ui.output')
local state = require('opencode.state')
local config = require('opencode.config')
local snapshot = require('opencode.snapshot')
local mention = require('opencode.ui.mention')
local permission_window = require('opencode.ui.permission_window')
local tool_formatters = require('opencode.ui.formatter.tools')
local format_utils = require('opencode.ui.formatter.utils')

local M = {}

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

  format_utils.format_action(output, icons.get('reasoning'), title, '')

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

---Format the revert callout with statistics
---@param session_data OpencodeMessage[] All messages in the session
---@param start_idx number Index of the message where revert occurred
---@return Output output object representing the lines, extmarks, and actions
function M._format_revert_message(session_data, start_idx)
  local output = Output.new()
  local stats = format_utils.calculate_revert_stats(session_data, start_idx, state.active_session.revert)
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

  output:add_empty_line()
  return output
end

---@param hidden_count integer
---@return Output
function M._format_hidden_messages_notice(hidden_count)
  local output = Output.new()
  local message_text = hidden_count == 1 and 'message is' or 'messages are'

  output:add_line(string.format('> %d older %s not displayed.', hidden_count, message_text))
  output:add_action({
    text = 'Show [A]ll messages',
    type = 'toggle_max_messages',
    args = {},
    key = 'A',
    display_line = output:get_line_count() - 1,
    range = { from = output:get_line_count() - 1, to = output:get_line_count() - 1 },
  })
  output:add_empty_line()

  return output
end

---@param output Output
---@param text string
---@param action_type string
---@param args any[]
---@param key? string
---@param line? integer
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
  format_utils.format_action(output, icons.get('snapshot'), 'Created Snapshot', vim.trim(part.hash:sub(1, 8)))

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
---@param previous_message? OpencodeMessage
---@return Output
function M.format_message_header(message, previous_message)
  local output = Output.new()

  if message.info and message.info.id == '__opencode_revert_message__' then
    output:add_lines(M.separator)
    return output
  end

  if message.info and message.info.id == '__opencode_hidden_messages_notice__' then
    return output
  end

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
    elseif state.current_mode and state.current_mode ~= '' then
      display_name = state.current_mode:upper()
    else
      display_name = 'ASSISTANT'
    end
  else
    display_name = role:upper()
  end

  local header_style = config.ui.output.compact_assistant_headers
  if header_style == true then
    header_style = 'minimal'
  end
  if header_style == false then
    header_style = 'full'
  end

  local same_mode_as_previous = false
  if (header_style == 'minimal' or header_style == 'hidden') and role == 'assistant' and previous_message then
    local previous_role = previous_message.info and previous_message.info.role or nil
    local previous_mode = previous_message.info and previous_message.info.mode or state.current_mode
    local current_mode = message.info.mode or state.current_mode
    same_mode_as_previous = previous_role == 'assistant'
      and current_mode
      and previous_mode
      and current_mode ~= ''
      and previous_mode ~= ''
      and current_mode == previous_mode
  end

  if not same_mode_as_previous then
    output:add_lines(M.separator)
  else
    if header_style ~= 'hidden' then
      output:add_line('')
    end
  end

  if not same_mode_as_previous then
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
  end

  if time and (role ~= 'assistant' or header_style ~= 'hidden') then
    output:add_extmark(output:get_line_count() - 1, {
      virt_text = { { (same_mode_as_previous and '' or ' ') .. util.format_time(time), 'OpencodeHint' } },
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
  local part_message = part._message_context
  local json = context_module.decode_json_context(part.text or '', 'selection')
  if not json then
    return
  end
  local start_line = output:get_line_count() + 1

  if part_message and part_message.parts then
    for i, message_part in ipairs(part_message.parts) do
      if message_part.id == part.id then
        local previous_part = part_message.parts[i - 1]
        if previous_part and previous_part.type == 'text' and previous_part.synthetic then
          local has_selection = context_module.decode_json_context(previous_part.text or '', 'selection') ~= nil
          local has_cursor = context_module.decode_json_context(previous_part.text or '', 'cursor-data') ~= nil
          local diagnostics = context_module.decode_json_context(previous_part.text or '', 'diagnostics')
          local has_diagnostics = diagnostics
            and diagnostics.content
            and type(diagnostics.content) == 'table'
            and #diagnostics.content > 0

          if has_selection or has_cursor or has_diagnostics then
            start_line = output:get_line_count()
          end
        end
        break
      end
    end
  end

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

---@param part OpencodeMessagePart|nil
---@return string|nil
local function get_visible_user_part_kind(part)
  if not part then
    return nil
  end

  if part.type == 'file' and part.filename and part.filename ~= '' then
    return 'file'
  end

  if part.type ~= 'text' or not part.text or part.text == '' then
    return nil
  end

  if not part.synthetic then
    return 'text'
  end

  if context_module.decode_json_context(part.text, 'selection') then
    return 'selection'
  end

  if context_module.decode_json_context(part.text, 'cursor-data') then
    return 'cursor-data'
  end

  local diagnostics = context_module.decode_json_context(part.text, 'diagnostics')
  if diagnostics and diagnostics.content and type(diagnostics.content) == 'table' and #diagnostics.content > 0 then
    return 'diagnostics'
  end

  return nil
end

---@param message OpencodeMessage|nil
---@param part OpencodeMessagePart|nil
---@return string|nil previous_kind
---@return string|nil next_kind
local function get_user_part_neighbors(message, part)
  if not message or not message.parts or not part or not part.id then
    return nil, nil
  end

  local current_index = nil
  for i, message_part in ipairs(message.parts) do
    if message_part.id == part.id then
      current_index = i
      break
    end
  end

  if not current_index then
    return nil, nil
  end

  local previous_kind = nil
  for i = current_index - 1, 1, -1 do
    previous_kind = get_visible_user_part_kind(message.parts[i])
    if previous_kind then
      break
    end
  end

  local next_kind = nil
  for i = current_index + 1, #message.parts do
    next_kind = get_visible_user_part_kind(message.parts[i])
    if next_kind then
      break
    end
  end

  return previous_kind, next_kind
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
---@param message_id string|nil Optional message ID for reference parsing
function M._format_assistant_message(output, text, message_id)
  local reference_picker = require('opencode.ui.reference_picker')
  local references = reference_picker.parse_references(text, message_id)

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
---@param part OpencodeMessagePart
---@param get_child_parts? fun(session_id: string): OpencodeMessagePart[]?
function M.format_tool(output, part, get_child_parts)
  local tool = part.tool
  if not tool or not part.state then
    return
  end

  local start_line = output:get_line_count() + 1

  local formatter = tool_formatters[tool] or tool_formatters.tool
  formatter.format(output, part, get_child_parts)

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
---@param start_line number
---@param end_line number
---@param hl_group string Highlight group for the border character
---@param win_col number
---@param text_hl_group? string Optional highlight group for the background/foreground of text lines
function M.add_vertical_border(output, start_line, end_line, hl_group, win_col, text_hl_group)
  local extmark_opts = {
    virt_text = { { require('opencode.ui.icons').get('border'), hl_group } },
    virt_text_pos = 'overlay',
    virt_text_win_col = win_col,
    virt_text_repeat_linebreak = true,
    line_hl_group = text_hl_group or nil,
  }

  for line = start_line, end_line do
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
        part._message_context = message
        M._format_selection_context(output, part)
        M._format_cursor_data_context(output, part)
        M._format_diagnostics_context(output, part)
        part._message_context = nil
      else
        M._format_user_prompt(output, vim.trim(part.text), message)
        content_added = true
      end
    elseif part.type == 'file' then
      local file_line = M._format_context_file(output, part.filename)
      if file_line then
        local previous_kind, next_kind = get_user_part_neighbors(message, part)
        local previous_is_context = previous_kind == 'selection'
          or previous_kind == 'cursor-data'
          or previous_kind == 'diagnostics'

        if next_kind == 'text' or (previous_is_context and not next_kind) then
          M.add_vertical_border(output, file_line - 1, file_line, 'OpencodeMessageRoleUser', -3)
        elseif next_kind == 'file' then
          M.add_vertical_border(output, file_line, file_line + 1, 'OpencodeMessageRoleUser', -3)
        else
          M.add_vertical_border(output, file_line, file_line, 'OpencodeMessageRoleUser', -3)
        end
        content_added = true
      end
    end
  elseif role == 'assistant' then
    if part.type == 'text' and part.text then
      M._format_assistant_message(output, vim.trim(part.text), part.messageID)
      content_added = true
    elseif part.type == 'reasoning' then
      M._format_reasoning(output, part)
      content_added = true
    elseif part.type == 'tool' then
      M.format_tool(output, part, get_child_parts)
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
    elseif part.type == 'revert-display' then
      local revert_index = part.state and part.state.revert_index
      if revert_index then
        output = M._format_revert_message(state.messages or {}, revert_index)
        content_added = output:get_line_count() > 0
      end
    elseif part.type == 'hidden-messages-display' then
      local hidden_count = part.state and part.state.hidden_count
      if type(hidden_count) == 'number' and hidden_count > 0 then
        output = M._format_hidden_messages_notice(hidden_count)
        content_added = output:get_line_count() > 0
      end
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
