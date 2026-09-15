local M = {}

local reference_parser = require('opencode.ui.reference_parser')

local current_session_id = nil
local current_refs = {}
local current_files = {}
local current_directory = nil

local function relative_path(path)
  if path:sub(1, 1) ~= '/' or not current_directory or not vim.startswith(path, current_directory .. '/') then
    return path
  end
  return path:sub(#current_directory + 2)
end

local function absolute_path(path)
  if path:sub(1, 1) == '/' then
    return path
  end
  return current_directory and (current_directory .. '/' .. path) or path
end

local function file_is_available(path)
  local absolute = absolute_path(path)
  if vim.fn.filereadable(absolute) == 1 then
    return true, absolute
  end
  return false, absolute
end

local function is_current_session_message(session_id, message, role)
  return current_session_id == session_id
    and message
    and message.session_id == session_id
    and message.kind == role
    and not (message.id and message.id:match('^__opencode_'))
end

local function is_current_session_assistant_message(session_id, message)
  return is_current_session_message(session_id, message, 'assistant')
end

local function is_current_session_user_message(session_id, message)
  return is_current_session_message(session_id, message, 'user')
end

local function collect_part_refs(session_id, message, part, message_order, part_order)
  if not part then
    return {}
  end

  if is_current_session_user_message(session_id, message) and part.kind == 'file' then
    local path = part.source and part.source.path or part.name
    if not path or path == '' then
      return {}
    end
    if not part.id then
      return {}
    end
    return {
      {
        session_id = session_id,
        message_id = message.id,
        part_id = part.id,
        path = relative_path(path),
        source_kind = 'user_file_part',
        order = message_order * 1000000 + part_order * 1000 + 1,
      },
    }
  end

  if not is_current_session_assistant_message(session_id, message) or part.synthetic or not part.id then
    return {}
  end

  local refs = {}
  local message_id = message.id

  if part.kind == 'text' and part.text then
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
  elseif part.kind == 'tool' then
    local file_path = part.target and part.target.path
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

local function rebuild_current_files()
  current_files = {}
  local seen = {}
  for _, ref in ipairs(current_refs) do
    local available, absolute = file_is_available(ref.path)
    if available and not seen[absolute] then
      seen[absolute] = true
      current_files[#current_files + 1] = absolute
    end
  end
end

function M.clear()
  current_session_id = nil
  current_refs = {}
  current_files = {}
  current_directory = nil
  reference_parser.clear_all()
end

---@param session_id string
---@param messages table[]
---@param location? table
function M.rebuild(session_id, messages, location)
  current_session_id = session_id
  current_directory = location and location.directory or nil
  current_refs = {}
  reference_parser.clear_all()

  for message_order, message in ipairs(messages or {}) do
    if is_current_session_assistant_message(session_id, message) or is_current_session_user_message(session_id, message) then
      for part_order, part in ipairs(message.content or {}) do
        if part.id then
          local refs = collect_part_refs(session_id, message, part, message_order, part_order)
          for _, ref in ipairs(refs) do
            current_refs[#current_refs + 1] = ref
          end
        end
      end
    end
  end

  rebuild_current_files()
end

---@return CodeReference[]
function M.current_refs()
  local refs = {}
  for _, ref in ipairs(current_refs) do
    refs[#refs + 1] = vim.deepcopy(ref)
  end

  return refs
end

---@return string[]
function M.current_files()
  return vim.deepcopy(current_files)
end

---Files eligible as symbol-search candidates: conversation refs plus all
---currently loaded plain-file buffers (one-shot snapshot, no event subscription).
---@return string[]
function M.available_files()
  local files = {}
  local seen = {}
  for _, path in ipairs(current_files) do
    if not seen[path] then
      seen[path] = true
      files[#files + 1] = path
    end
  end
  for _, bufinfo in ipairs(vim.fn.getbufinfo({ bufloaded = 1 })) do
    local name = bufinfo.name
    if name ~= '' and vim.bo[bufinfo.bufnr].buftype == '' and not seen[name] then
      seen[name] = true
      files[#files + 1] = name
    end
  end
  return files
end

function M.refresh_current_files()
  rebuild_current_files()
end

return M
