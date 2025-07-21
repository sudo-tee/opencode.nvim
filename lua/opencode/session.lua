local util = require('opencode.util')
local M = {}

---@param dir string Directory path to read JSON files from
---@param max_items? number Maximum number of items to read
---@return table[]|nil Array of decoded JSON objects
function M.read_json_dir(dir, max_items)
  if not dir or vim.fn.isdirectory(dir) == 0 then
    return nil
  end

  local count = 0
  local decoded_items = {}
  for file, file_type in vim.fs.dir(dir) do
    if file_type == 'file' and file:match('%.json$') then
      local file_ok, content = pcall(vim.fn.readfile, dir .. '/' .. file)
      if file_ok then
        local lines = table.concat(content, '\n')
        local ok, data = pcall(vim.json.decode, lines)
        if ok and data then
          table.insert(decoded_items, data)
        end
      end
    end
    count = count + 1
    if max_items and count >= max_items then
      break
    end
  end

  if #decoded_items == 0 then
    return nil
  end
  return decoded_items
end

function M.workspace_slug(path)
  local is_git_project = util.is_git_project()
  if not is_git_project then
    return 'global'
  end

  local workspace = path or vim.fn.getcwd()
  local sep = package.config:sub(1, 1)
  local slug = workspace
    :gsub(vim.pesc(sep), '-')
    :gsub('[^A-Za-z0-9_-]', '-') -- Replace non-alphanumeric characters with dashes
    :gsub('^%-+', '') -- Remove leading dashes
    :gsub('%-+$', '') -- Remove trailing dashes

  return slug
end

function M.get_workspace_session_path(workspace)
  workspace = workspace or M.workspace_slug()
  local home = vim.uv.os_homedir()
  return home .. '/.local/share/opencode/project/' .. workspace .. '/storage/session'
end

function M.get_workspace_snapshot_path(workspace)
  workspace = workspace or M.workspace_slug()
  local home = vim.uv.os_homedir()
  return home .. '/.local/share/opencode/project/' .. workspace .. '/snapshot/'
end

---@return Session[]|nil
function M.get_all_sessions()
  local sessions_dir = M.get_workspace_session_path()
  local info_dir = sessions_dir .. '/info'

  local sessions = {}
  for name, type_ in vim.fs.dir(info_dir) do
    if type_ == 'file' then
      local file = info_dir .. '/' .. name
      local content = table.concat(vim.fn.readfile(file), '\n')
      local ok, session = pcall(vim.json.decode, content)
      if ok and session then
        table.insert(sessions, session)
      end
    end
  end

  if #sessions == 0 then
    return nil
  end

  return vim.tbl_map(M.create_session_object, sessions)
end

function M.create_session_object(session_json)
  local sessions_dir = M.get_workspace_session_path()
  return {
    workspace = vim.fn.getcwd(),
    description = session_json.title or '',
    modified = session_json.time and session_json.time.updated or os.time(),
    name = session_json.id,
    parentID = session_json.parentID,
    path = sessions_dir .. '/info/' .. session_json.id .. '.json',
    messages_path = sessions_dir .. '/message/' .. session_json.id,
    parts_path = sessions_dir .. '/part/' .. session_json.id .. '/',
    snapshot_path = M.get_workspace_snapshot_path() .. session_json.id .. '/',
    workplace_slug = M.workspace_slug(),
  }
end

---@return Session[]|nil
function M.get_all_workspace_sessions()
  local sessions = M.get_all_sessions()
  if not sessions then
    return nil
  end

  table.sort(sessions, function(a, b)
    return a.modified > b.modified
  end)

  if not util.is_git_project() then
    -- we only want sessions that are in the current workspace_folder
    sessions = vim.tbl_filter(function(session)
      local first_messages = M.get_messages(session, false, 2)
      if first_messages and #first_messages > 1 then
        local first_assistant_message = first_messages[2]
        return first_assistant_message.path and first_assistant_message.path.root == vim.fn.getcwd()
      end
      return false
    end, sessions)
  end

  return sessions
end

---@return Session|nil
function M.get_last_workspace_session()
  local sessions = M.get_all_workspace_sessions()
  if not sessions then
    return nil
  end

  local main_sessions = vim.tbl_filter(function(session)
    return session.parentID == nil --- we don't want child sessions
  end, sessions)

  -- read the first messages to ensure they have the right path

  return main_sessions[1]
end

local _session_by_name = {}
local _session_last_modified = {}

---@param name string
---@return Session|nil
function M.get_by_name(name)
  local sessions_dir = M.get_workspace_session_path()
  local info_dir = sessions_dir .. '/info'
  local file = info_dir .. '/' .. name .. '.json'
  local _, stat = pcall(vim.uv.fs_stat, file)
  if not stat then
    return nil
  end

  if _session_by_name[name] and _session_last_modified[name] == stat.mtime.sec then
    return _session_by_name[name]
  end

  local content = table.concat(vim.fn.readfile(file), '\n')
  local ok, session_json = pcall(vim.json.decode, content)
  if not ok or not session_json then
    return nil
  end

  local session = M.create_session_object(session_json)
  _session_by_name[name] = session
  _session_last_modified[name] = stat.mtime.sec

  return session
end

---@param session Session
---@param include_parts? boolean Whether to include message parts
---@param max_items? number Maximum number of messages to return
function M.get_messages(session, include_parts, max_items)
  include_parts = include_parts == nil and true or include_parts
  if not session then
    return nil
  end

  local messages = M.read_json_dir(session.messages_path)
  if not messages then
    return nil
  end

  local count = 0
  for _, message in ipairs(messages) do
    count = count + 1
    if not message.parts or #message.parts == 0 then
      message.parts = include_parts and M.get_message_parts(message, session) or {}
    end
    if max_items and count >= max_items then
      break
    end
  end

  return messages
end

---@param message Message
---@param session Session
function M.get_message_parts(message, session)
  local parts_path = session.parts_path .. message.id
  return M.read_json_dir(parts_path)
end

---@param message Message
---@return string[]|nil
function M.get_message_snapshot_ids(message)
  if not message then
    return nil
  end
  local snapshot_ids = {}
  for _, part in ipairs(message.parts or {}) do
    if part.snapshot and not vim.tbl_contains(snapshot_ids, part.snapshot) then
      table.insert(snapshot_ids, part.snapshot)
    end
  end
  return #snapshot_ids > 0 and snapshot_ids or nil
end

return M
