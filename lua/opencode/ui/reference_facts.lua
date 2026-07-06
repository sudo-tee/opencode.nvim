local M = {}

local reference_parser = require('opencode.ui.reference_parser')

local current_session_id = nil
local messages_by_id = {}
local next_message_order = 1
local current_files = {}

local function relative_path(path)
  if path:sub(1, 1) ~= '/' then
    return path
  end
  return vim.fn.fnamemodify(path, ':~:.')
end

local function absolute_path(path)
  if path:sub(1, 1) == '/' then
    return path
  end
  return vim.fn.getcwd() .. '/' .. path
end

local function file_is_available(path)
  local absolute = absolute_path(path)
  if vim.fn.filereadable(absolute) == 1 then
    return true, absolute
  end
  return false, absolute
end

local function is_current_session_assistant_message(session_id, message)
  return current_session_id == session_id
    and message
    and message.info
    and message.info.sessionID == session_id
    and message.info.role == 'assistant'
    and not (message.info.id and message.info.id:match('^__opencode_'))
end

local function collect_part_refs(session_id, message, part, message_order, part_order)
  if not is_current_session_assistant_message(session_id, message) or not part or part.synthetic or not part.id then
    return {}
  end

  local refs = {}
  local message_id = message.info.id

  if part.type == 'text' and part.text then
    for ref_order, parsed in ipairs(reference_parser.parse_references(part.text, part.id)) do
      table.insert(refs, {
        session_id = session_id,
        message_id = message_id,
        part_id = part.id,
        path = parsed.file_path,
        line = parsed.line,
        col = parsed.col,
        source_kind = 'assistant_text',
        raw_range = {
          start_offset = parsed.match_start,
          end_offset = parsed.match_end,
        },
        order = message_order * 1000000 + part_order * 1000 + ref_order,
      })
    end
  elseif part.type == 'tool' then
    local file_path = vim.tbl_get(part, 'state', 'input', 'filePath')
    if file_path and file_path ~= '' then
      table.insert(refs, {
        session_id = session_id,
        message_id = message_id,
        part_id = part.id,
        path = relative_path(file_path),
        source_kind = 'tool_file_path',
        order = message_order * 1000000 + part_order * 1000 + 1,
      })
    end
  end

  return refs
end

local function refs_equal(a, b)
  if #(a or {}) ~= #(b or {}) then
    return false
  end
  for i = 1, #a do
    local left = a[i]
    local right = b[i]
    if
      left.path ~= right.path
      or left.line ~= right.line
      or left.col ~= right.col
      or left.source_kind ~= right.source_kind
    then
      return false
    end
  end
  return true
end

local function all_refs()
  local entries = {}
  for _, entry in pairs(messages_by_id) do
    entries[#entries + 1] = entry
  end
  table.sort(entries, function(a, b)
    return a.order < b.order
  end)

  local refs = {}
  for _, entry in ipairs(entries) do
    local parts = {}
    for _, part_entry in pairs(entry.parts) do
      parts[#parts + 1] = part_entry
    end
    table.sort(parts, function(a, b)
      return a.order < b.order
    end)

    for _, part_entry in ipairs(parts) do
      for _, ref in ipairs(part_entry.refs) do
        refs[#refs + 1] = ref
      end
    end
  end

  return refs
end

local function rebuild_current_files()
  current_files = {}
  local seen = {}
  for _, ref in ipairs(all_refs()) do
    local available, absolute = file_is_available(ref.path)
    if available and not seen[absolute] then
      seen[absolute] = true
      current_files[#current_files + 1] = absolute
    end
  end
end

local function ensure_message_entry(message)
  local message_id = message and message.info and message.info.id
  if not message_id then
    return nil
  end

  local entry = messages_by_id[message_id]
  if not entry then
    entry = {
      message = message,
      order = next_message_order,
      parts = {},
    }
    next_message_order = next_message_order + 1
    messages_by_id[message_id] = entry
  end
  entry.message = message
  return entry
end

local function replace_part_entry(session_id, message, part)
  local message_id = message and message.info and message.info.id
  local part_id = part and part.id
  if not message_id or not part_id then
    return false
  end

  if not is_current_session_assistant_message(session_id, message) then
    local entry = messages_by_id[message_id]
    if entry and entry.parts[part_id] then
      entry.parts[part_id] = nil
      return true
    end
    return false
  end

  local entry = ensure_message_entry(message)
  local part_order = 1
  for index, candidate in ipairs(message.parts or {}) do
    if candidate.id == part_id then
      part_order = index
      break
    end
  end

  local old_refs = entry.parts[part_id] and entry.parts[part_id].refs or {}
  local refs = collect_part_refs(session_id, message, part, entry.order, part_order)
  if #refs > 0 then
    entry.parts[part_id] = { order = part_order, refs = refs }
  else
    entry.parts[part_id] = nil
  end
  return not refs_equal(old_refs, refs)
end

function M.clear()
  current_session_id = nil
  messages_by_id = {}
  next_message_order = 1
  current_files = {}
  reference_parser.clear_all()
end

---@param session_id string
---@param messages OpencodeMessage[]
function M.rebuild(session_id, messages)
  current_session_id = session_id
  messages_by_id = {}
  next_message_order = 1
  reference_parser.clear_all()

  for message_order, message in ipairs(messages or {}) do
    if is_current_session_assistant_message(session_id, message) then
      local entry = {
        message = message,
        order = message_order,
        parts = {},
      }
      messages_by_id[message.info.id] = entry
      next_message_order = math.max(next_message_order, message_order + 1)

      for part_order, part in ipairs(message.parts or {}) do
        if part.id then
          local refs = collect_part_refs(session_id, message, part, message_order, part_order)
          if #refs > 0 then
            entry.parts[part.id] = { order = part_order, refs = refs }
          end
        end
      end
    end
  end

  rebuild_current_files()
end

---@param session_id string
---@param message OpencodeMessage
---@param part OpencodeMessagePart
---@return boolean refs_changed
function M.replace_part(session_id, message, part)
  if not current_session_id then
    current_session_id = session_id
  end
  local changed = replace_part_entry(session_id, message, part)
  if changed then
    rebuild_current_files()
  end
  return changed
end

---@param message_id string
---@param part_id string
---@return boolean refs_changed
function M.remove_part(message_id, part_id)
  reference_parser.clear(part_id)
  local entry = messages_by_id[message_id]
  local had_refs = entry and entry.parts[part_id] and #(entry.parts[part_id].refs or {}) > 0
  if entry then
    entry.parts[part_id] = nil
  end
  if had_refs then
    rebuild_current_files()
  end
  return had_refs == true
end

---@param message_id string
---@return boolean refs_changed
function M.remove_message(message_id)
  local entry = messages_by_id[message_id]
  local had_refs = false
  if entry then
    for part_id, part_entry in pairs(entry.parts) do
      reference_parser.clear(part_id)
      if #(part_entry.refs or {}) > 0 then
        had_refs = true
      end
    end
  end
  messages_by_id[message_id] = nil
  if had_refs then
    rebuild_current_files()
  end
  return had_refs
end

---@return CodeReference[]
function M.current_refs()
  local refs = {}
  for _, ref in ipairs(all_refs()) do
    refs[#refs + 1] = vim.deepcopy(ref)
  end

  return refs
end

---@return string[]
function M.current_files()
  return vim.deepcopy(current_files)
end

function M.refresh_current_files()
  rebuild_current_files()
end

return M
