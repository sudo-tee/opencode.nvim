local util = require('opencode.util')

local M = {}

---Compute duration text for a tool part, returning nil when not applicable.
---@param part OpencodeMessagePart
---@return string|nil
function M.get_duration_text(part)
  local status = part.state and part.state.status
  if status == 'pending' then
    return nil
  end
  local time = part.state and part.state.time or {}
  return util.format_duration_seconds(time.start, time['end'])
end

---@param icon string Icon text (result of `icons.get(key)`) or empty string
---@param tool_type string Tool type (e.g., 'run', 'read', 'edit', etc.)
---@param value string Value associated with the action (e.g., filename, command)
---@param duration_text? string
---@return string
function M.build_action_line(icon, tool_type, value, duration_text)
  local detail = value and #value > 0 and ('`' .. value .. '`') or ''
  local duration_suffix = duration_text and (' ' .. duration_text) or ''
  return string.format('**%s %s** %s%s', icon, tool_type, detail, duration_suffix)
end

---@param output Output Output object to write to
---@param icon string Icon text (result of `icons.get(key)`) or empty string
---@param tool_type string Tool type (e.g., 'run', 'read', 'edit', etc.)
---@param value string Value associated with the action (e.g., filename, command)
---@param duration_text? string
function M.format_action(output, icon, tool_type, value, duration_text)
  if not icon or not tool_type then
    return
  end
  output:add_line(M.build_action_line(icon, tool_type, value, duration_text))
end

---@param output Output Output object to write to
---@param lines string[]
---@param language string
function M.format_code(output, lines, language)
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

---@param output Output
---@param code string
---@param file_type string
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
---Calculate statistics for reverted messages and tool calls
---@param messages {info: MessageInfo, parts: OpencodeMessagePart[]}[] All messages in the session
---@param revert_index number Index of the message where revert occurred
---@param revert_info SessionRevertInfo|nil Revert information
---@return {messages: number, tool_calls: number, files: table<string, {additions: number, deletions: number}>}
function M.calculate_revert_stats(messages, revert_index, revert_info)
  local stats = {
    messages = 0,
    tool_calls = 0,
    files = {}, -- { [filename] = { additions = n, deletions = m } }
  }

  for i = revert_index, #messages do
    local msg = messages[i]
    if msg and msg.info and msg.info.role == 'user' then
      stats.messages = stats.messages + 1
    end
    if msg and msg.parts then
      for _, part in ipairs(msg.parts) do
        if part.type == 'tool' then
          stats.tool_calls = stats.tool_calls + 1
        end
      end
    end
  end

  if revert_info and revert_info.diff then
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

return M
