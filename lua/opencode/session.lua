local util = require('opencode.util')
local M = {}

---Get the current OpenCode project ID
---@return string|nil
function M.project_id()
  local config_file = require('opencode.config_file')
  local project = config_file.get_opencode_project()
  if not project then
    vim.notify('No OpenCode project found in the current directory', vim.log.levels.ERROR)
    return nil
  end
  return project.id
end

---Get the base storage path for OpenCode
---@return string
function M.get_storage_path()
  local home = vim.uv.os_homedir()
  return home .. '/.local/share/opencode/storage'
end

---Get the session storage path for the current workspace
---@return string
function M.get_workspace_session_path(project_id)
  project_id = project_id or M.project_id() or ''
  local home = vim.uv.os_homedir()
  return home .. '/.local/share/opencode/storage/session/' .. project_id
end

---Get the snapshot storage path for the current workspace
---@return string
function M.get_workspace_snapshot_path()
  local project_id = M.project_id()
  local home = vim.uv.os_homedir()
  return home .. '/.local/share/opencode/snapshot/' .. project_id
end

---@return Session[]|nil
---Get all sessions for the current workspace
---@return Session[]|nil
function M.get_all_sessions()
  local sessions_dir = M.get_workspace_session_path()

  local sessions = {}
  local ok_iter, iter = pcall(vim.fs.dir, sessions_dir)
  if not ok_iter or not iter then
    return nil
  end
  for name, type_ in iter do
    if type_ == 'file' then
      local file = sessions_dir .. '/' .. name
      local content_ok, content = pcall(vim.fn.readfile, file)
      if content_ok then
        local joined = table.concat(content, '\n')
        local ok, session = pcall(vim.json.decode, joined)
        if ok and session then
          table.insert(sessions, session)
        end
      end
    end
  end

  if #sessions == 0 then
    return nil
  end

  return vim.tbl_map(M.create_session_object, sessions)
end

---Create a Session object from JSON
---@param session_json table
---@return Session
function M.create_session_object(session_json)
  local sessions_dir = M.get_workspace_session_path()
  local storage_path = M.get_storage_path()
  return {
    workspace = vim.fn.getcwd(),
    description = session_json.title or '',
    modified = session_json.time and session_json.time.updated or os.time(),
    name = session_json.id,
    parentID = session_json.parentID,
    path = sessions_dir .. '/' .. session_json.id .. '.json',
    messages_path = storage_path .. '/message/' .. session_json.id,
    parts_path = storage_path .. '/part',
    cache_path = vim.fn.stdpath('cache') .. '/opencode/session/' .. session_json.id,
    snapshot_path = M.get_workspace_snapshot_path(),
    project_id = M.project_id(),
  }
end

---@return Session[]|nil
---Get all workspace sessions, sorted and filtered
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
---Get the most recent main workspace session
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

---Get a session by its name
---@param name string
---@return Session|nil
function M.get_by_name(name)
  if not name or name == '' then
    return nil
  end
  local sessions_dir = M.get_workspace_session_path()
  local file = sessions_dir .. '/' .. name .. '.json'
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

---Get messages for a session
---@param session Session
---@param include_parts? boolean Whether to include message parts
---@param max_items? number Maximum number of messages to return
---@return Message[]|nil
function M.get_messages(session, include_parts, max_items)
  include_parts = include_parts == nil and true or include_parts
  if not session then
    return nil
  end

  local messages = util.read_json_dir(session.messages_path)
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
  table.sort(messages, function(a, b)
    return a.time.created < b.time.created
  end)

  return messages
end

---Get parts for a message
---@param message Message
---@param session Session
---@return MessagePart[]|nil
function M.get_message_parts(message, session)
  local parts_path = session.parts_path .. '/' .. message.id
  return util.read_json_dir(parts_path)
end

---Get snapshot IDs from a message's parts
---@param message Message
---@return string[]|nil
function M.get_message_snapshot_ids(message)
  if not message then
    return nil
  end
  local snapshot_ids = {}
  for _, part in ipairs(message.parts or {}) do
    if part.type == 'patch' and part.hash and not vim.tbl_contains(snapshot_ids, part.hash) then
      table.insert(snapshot_ids, part.hash)
    end
  end
  return #snapshot_ids > 0 and snapshot_ids or nil
end

return M
