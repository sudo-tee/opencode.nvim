-- Code reference picker for navigating to file references in LLM responses
local state = require('opencode.state')
local config = require('opencode.config')
local base_picker = require('opencode.ui.base_picker')
local icons = require('opencode.ui.icons')

local M = {}

---Check if a file reference is valid
---@param path string File path
---@param context string Surrounding text
---@return boolean
local function is_valid_file_reference(path, context)
  -- Reject URLs (but allow file paths that merely contain these substrings)
  local lower = context:lower()
  -- Match http/https URLs at word boundaries or www.-style URLs
  if lower:match('%f[%w]https?://%S+') or lower:match('%f[%w]www%.[%w%-_]+') then
    return false
  end

  return (path:match('%.[%w]+$') and vim.fn.filereadable(path) == 1) or false
end

---@class CodeReference
---@field file_path string Relative or absolute file path
---@field line number|nil Line number (1-indexed)
---@field column number|nil Column number (optional)
---@field message_id string ID of the message containing this reference
---@field match_start number Start position in original text
---@field match_end number End position in original text
---@field file string Absolute file path (for Snacks picker preview)
---@field pos number[]|nil Position as {line, col} for Snacks picker preview
---@field end_pos number[]|nil End position as {line, col} for Snacks picker range highlighting

---Create absolute path from relative path
---@param path string
---@return string
local function make_absolute_path(path)
  if not vim.startswith(path, '/') then
    return vim.fn.getcwd() .. '/' .. path
  end
  return path
end

---Create a CodeReference object from parsed components
---@param path string
---@param line number|nil
---@param column number|nil
---@param end_line number|nil
---@param message_id string
---@param match_start number
---@param match_end number
---@return CodeReference
local function create_code_reference(path, line, column, end_line, message_id, match_start, match_end)
  local abs_path = make_absolute_path(path)

  return {
    file_path = path,
    line = line,
    column = column,
    message_id = message_id,
    match_start = match_start,
    match_end = match_end,
    file = abs_path,
    pos = line and { line, (column or 1) - 1 } or nil,
    end_pos = end_line and { end_line, 0 } or nil,
  }
end

---Parse line, column, and range information from pattern captures
---@param line_str string
---@param col_or_end_str string
---@param end_line_str string
---@return number|nil line, number|nil column, number|nil end_line
local function parse_position_info(line_str, col_or_end_str, end_line_str)
  local line = line_str ~= '' and tonumber(line_str) or nil
  local column = nil
  local end_line = nil

  if end_line_str ~= '' then
    end_line = tonumber(end_line_str)
  elseif col_or_end_str ~= '' then
    column = tonumber(col_or_end_str)
  end

  return line, column, end_line
end

---Parse file references using a pattern
---@param text string The text to parse
---@param pattern string Lua pattern to match
---@param message_id string The message ID for tracking
---@return CodeReference[]
local function parse_references_with_pattern(text, pattern, message_id)
  local references = {}
  local search_start = 1

  while search_start <= #text do
    local match_start, match_end, path, line_str, col_or_end_str, end_line_str = text:find(pattern, search_start)
    if not match_start then
      break
    end

    local context_start = math.max(1, match_start - 30)
    local context = text:sub(context_start, match_end + 10)

    if path and is_valid_file_reference(path, context) then
      local line, column, end_line = parse_position_info(line_str, col_or_end_str, end_line_str)
      local ref = create_code_reference(path, line, column, end_line, message_id, match_start, match_end)
      table.insert(references, ref)
    end

    search_start = match_end + 1
  end

  return references
end

---Parse file references from text using multiple pattern strategies
---@param text string The text to parse
---@param message_id string The message ID for tracking
---@return CodeReference[]
function M.parse_references(text, message_id)
  local all_refs = {}

  local patterns = {
    '`([^`\n]+%.%w+):?(%d*):?(%d*)-?(%d*)`', -- Backticks: `file.ext:line`
    'file://([%S]+%.%w+):?(%d*):?(%d*)-?(%d*)', -- file:// URIs
    '([%w_./%-]+/[%w_./%-]*%.%w+):?(%d*):?(%d*)-?(%d*)', -- Paths with /
    '([%w_%-]+%.%w+):?(%d*):?(%d*)-?(%d*)', -- Top-level files
  }

  for _, pattern in ipairs(patterns) do
    local refs = parse_references_with_pattern(text, pattern, message_id)
    vim.list_extend(all_refs, refs)
  end

  -- Sort by position and deduplicate
  table.sort(all_refs, function(a, b)
    return a.match_start < b.match_start
  end)

  local deduplicated = {}
  for _, ref in ipairs(all_refs) do
    local last = deduplicated[#deduplicated]
    if not last or ref.match_start > last.match_end then
      table.insert(deduplicated, ref)
    end
  end

  return deduplicated
end

---Collect all references from assistant messages in the current session
---Returns references in reverse order (most recent first)
---@return CodeReference[]
function M.collect_references()
  local all_references = {}

  if not state.messages then
    return all_references
  end

  for i = #state.messages, 1, -1 do
    local msg = state.messages[i]

    if msg.info and msg.info.role == 'assistant' then
      local refs = msg.references or M._parse_message_references(msg)
      for _, ref in ipairs(refs) do
        table.insert(all_references, ref)
      end
    end
  end

  -- Keep first occurrence which is most recent due to reverse iteration
  local seen = {}
  local deduplicated = {}
  for _, ref in ipairs(all_references) do
    local normalized_path = vim.fn.fnamemodify(ref.file_path, ':p')
    local dedup_key = normalized_path .. ':' .. (ref.line or 0)
    if not seen[dedup_key] then
      seen[dedup_key] = true
      table.insert(deduplicated, ref)
    end
  end

  return deduplicated
end

---Parse references from a single message's text parts
---@param msg OpencodeMessage
---@return CodeReference[]
function M._parse_message_references(msg)
  local refs = {}
  if not msg.parts then
    return refs
  end

  local message_id = msg.info and msg.info.id or ''
  for _, part in ipairs(msg.parts) do
    if part.type == 'text' and part.text then
      local part_refs = M.parse_references(part.text, message_id)
      for _, ref in ipairs(part_refs) do
        table.insert(refs, ref)
      end
    end

    if part.type == 'tool' then
      local file_path = vim.tbl_get(part, 'state', 'input', 'filePath')
      if file_path and vim.fn.filereadable(file_path) == 1 then
        local relative_path = vim.fn.fnamemodify(file_path, ':~:.')
        local ref = create_code_reference(relative_path, nil, nil, nil, message_id, 0, 0)
        table.insert(refs, ref)
      end
    end
  end
  return refs
end

---Parse and cache references for all assistant messages in the current session
function M._parse_session_messages()
  if not state.messages then
    return
  end

  for _, msg in ipairs(state.messages) do
    if msg.info and msg.info.role == 'assistant' and not msg.references then
      msg.references = M._parse_message_references(msg)
    end
  end
end

---Setup reference picker event subscriptions
---Should be called once during plugin initialization
function M.setup()
  if state.event_manager then
    state.event_manager:subscribe('session.idle', function()
      M._parse_session_messages()
    end)
  end

  state.subscribe('messages', function()
    M._parse_session_messages()
  end)
end

---Format a reference for display in the picker
---@param ref CodeReference
---@param width number|nil
---@return PickerItem
local function format_reference_item(ref, width)
  local icon = icons.get('file')
  local location = ref.file_path

  if ref.line then
    location = location .. ':' .. ref.line
    if ref.end_pos and ref.end_pos[1] then
      location = location .. '-' .. ref.end_pos[1]
    elseif ref.column then
      location = location .. ':' .. ref.column
    end
  end

  local display_text = icon .. ' ' .. location

  return base_picker.create_time_picker_item(display_text, nil, nil, width)
end

---Open the reference picker
function M.pick()
  local references = M.collect_references()

  if #references == 0 then
    vim.notify('No code references found in the conversation', vim.log.levels.INFO)
    return
  end

  local callback = function(selected)
    if selected then
      M.navigate_to(selected)
    end
  end

  return base_picker.pick({
    items = references,
    format_fn = format_reference_item,
    actions = {},
    callback = callback,
    title = 'Code References (' .. #references .. ')',
    width = config.ui.picker_width or 100,
    preview = 'file',
    layout_opts = config.ui.picker,
  })
end

---Navigate to a code reference
---@param ref CodeReference
function M.navigate_to(ref)
  local file_path = make_absolute_path(ref.file_path)

  vim.cmd('tabedit ' .. vim.fn.fnameescape(file_path))

  if ref.line then
    local line = math.max(1, ref.line)
    local col = ref.column and math.max(0, ref.column - 1) or 0

    local line_count = vim.api.nvim_buf_line_count(0)
    line = math.min(line, line_count)

    vim.api.nvim_win_set_cursor(0, { line, col })
    if config.ui.reference_picker_center_on_jump then
      vim.cmd('normal! zz')
    end
  end
end

return M
