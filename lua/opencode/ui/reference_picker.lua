-- Code reference picker for navigating to file:// URI references in LLM responses
local state = require('opencode.state')
local config = require('opencode.config')
local base_picker = require('opencode.ui.base_picker')
local icons = require('opencode.ui.icons')

local M = {}

---Check if a file exists
---@param file_path string
---@return boolean
local function file_exists(file_path)
  local path = file_path
  -- Make absolute if relative
  if not vim.startswith(path, '/') then
    path = vim.fn.getcwd() .. '/' .. path
  end
  return vim.fn.filereadable(path) == 1
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

---Parse file:// URI references from text
---@param text string The text to parse
---@param message_id string The message ID for tracking
---@return CodeReference[]
function M.parse_references(text, message_id)
  local references = {}

  -- Match file:// URIs with optional line and column numbers or line ranges
  -- Formats: file://path/to/file or file://path/to/file:line or file://path/to/file:line:column or file://path/to/file:line-endline
  local pattern = 'file://([%w_./%-]+):?(%d*):?(%d*)-?(%d*)'
  local search_start = 1

  while search_start <= #text do
    local match_start, match_end, path, line_str, col_or_end_str, end_line_str = text:find(pattern, search_start)
    if not match_start then
      break
    end

    -- Only add if file exists
    if file_exists(path) then
      local line = line_str ~= '' and tonumber(line_str) or nil
      local column = nil
      local end_line = nil

      -- Determine if we have a range or a column
      if end_line_str ~= '' then
        -- Range format: file://path:start-end
        end_line = tonumber(end_line_str)
      elseif col_or_end_str ~= '' then
        -- Column format: file://path:line:col
        column = tonumber(col_or_end_str)
      end

      -- Create absolute path for Snacks preview
      local abs_path = path
      if not vim.startswith(path, '/') then
        abs_path = vim.fn.getcwd() .. '/' .. path
      end

      table.insert(references, {
        file_path = path,
        line = line,
        column = column,
        message_id = message_id,
        match_start = match_start,
        match_end = match_end,
        file = abs_path,
        pos = line and { line, (column or 1) - 1 } or nil,
        end_pos = end_line and { end_line, 0 } or nil,
      })
    end

    search_start = match_end + 1
  end

  return references
end

---Collect all references from assistant messages in the current session
---Returns references in reverse order (most recent first)
---@return CodeReference[]
function M.collect_references()
  local all_references = {}

  if not state.messages then
    return all_references
  end

  -- Process messages in reverse order (most recent first)
  for i = #state.messages, 1, -1 do
    local msg = state.messages[i]

    -- Only process assistant messages
    if msg.info and msg.info.role == 'assistant' then
      -- Use cached references if available, otherwise parse on-demand
      local refs = msg.references or M._parse_message_references(msg)
      for _, ref in ipairs(refs) do
        table.insert(all_references, ref)
      end
    end
  end

  -- Deduplicate across all messages (keep first occurrence which is most recent)
  local seen = {}
  local deduplicated = {}
  for _, ref in ipairs(all_references) do
    local dedup_key = ref.file_path .. ':' .. (ref.line or 0)
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
  end
  return refs
end

---Parse and cache references for all assistant messages in the current session
function M._parse_session_messages()
  if not state.messages then
    return
  end

  for _, msg in ipairs(state.messages) do
    -- Only parse assistant messages that don't already have references cached
    if msg.info and msg.info.role == 'assistant' and not msg.references then
      msg.references = M._parse_message_references(msg)
    end
  end
end

---Setup reference picker event subscriptions
---Should be called once during plugin initialization
function M.setup()
  -- Subscribe to session.idle to parse references when AI is done responding
  if state.event_manager then
    state.event_manager:subscribe('session.idle', function()
      M._parse_session_messages()
    end)
  end

  -- Subscribe to messages changes to handle session loads
  state.subscribe('messages', function()
    -- Parse any messages that don't have cached references
    -- This handles loading previous sessions
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

  return base_picker.create_picker_item(display_text, nil, nil, width)
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
  local file_path = ref.file_path

  -- Make absolute if relative
  if not vim.startswith(file_path, '/') then
    file_path = vim.fn.getcwd() .. '/' .. file_path
  end

  -- Open the file in a new tab
  vim.cmd('tabedit ' .. vim.fn.fnameescape(file_path))

  -- Jump to line if specified
  if ref.line then
    local line = math.max(1, ref.line)
    local col = ref.column and math.max(0, ref.column - 1) or 0

    -- Make sure we don't exceed buffer line count
    local line_count = vim.api.nvim_buf_line_count(0)
    line = math.min(line, line_count)

    vim.api.nvim_win_set_cursor(0, { line, col })
    vim.cmd('normal! zz') -- Center the view
  end
end

return M
