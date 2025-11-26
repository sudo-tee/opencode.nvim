local util = require('opencode.util')
local config_file = require('opencode.config_file')
local Promise = require('opencode.promise')
local M = {}

---Get the current OpenCode project ID
---@return string|nil
function M.project_id()
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
  local state = require('opencode.state')
  local ok, result = pcall(function()
    return state.api_client:list_sessions():wait()
  end)

  if not ok then
    vim.notify('Failed to fetch session list: ' .. vim.inspect(result), vim.log.levels.ERROR)
    return nil
  end

  return vim.tbl_map(M.create_session_object, result --[[@as Session[] ]])
end

---Create a Session object from JSON
---@param session_json table
---@return Session
function M.create_session_object(session_json)
  local sessions_dir = M.get_workspace_session_path()
  local storage_path = M.get_storage_path()
  return {
    workspace = session_json.directory,
    title = session_json.title or '',
    modified = session_json.time and session_json.time.updated or os.time(),
    id = session_json.id,
    parentID = session_json.parentID,
    path = sessions_dir .. '/' .. session_json.id .. '.json',
    messages_path = storage_path .. '/message/' .. session_json.id,
    parts_path = storage_path .. '/part',
    cache_path = vim.fn.stdpath('cache') .. '/opencode/session/' .. session_json.id,
    snapshot_path = M.get_workspace_snapshot_path(),
    project_id = M.project_id(),
    revert = session_json.revert or nil,
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
      if session.workspace and vim.startswith(vim.fn.getcwd(), session.workspace) then
        return true
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

  return main_sessions[1]
end

local _session_by_id = {}
local _session_last_modified = {}

---Get a session by its id
---@param id string
---@return Session|nil
function M.get_by_id(id)
  if not id or id == '' then
    return nil
  end
  local sessions_dir = M.get_workspace_session_path()
  local file = sessions_dir .. '/' .. id .. '.json'
  local _, stat = pcall(vim.uv.fs_stat, file)
  if not stat then
    return nil
  end

  if _session_by_id[id] and _session_last_modified[id] == stat.mtime.sec then
    return _session_by_id[id]
  end

  local content = table.concat(vim.fn.readfile(file), '\n')
  local ok, session_json = pcall(vim.json.decode, content)
  if not ok or not session_json then
    return nil
  end

  local session = M.create_session_object(session_json)
  _session_by_id[id] = session
  _session_last_modified[id] = stat.mtime.sec

  return session
end

---Get messages for a session
---@param session Session
---@return Promise<OpencodeMessage[]>
function M.get_messages(session)
  local state = require('opencode.state')
  if not session then
    return Promise.new():resolve(nil)
  end

  return state.api_client:list_messages(session.id)
end

---Get snapshot IDs from a message's parts
---@param message OpencodeMessage?
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
