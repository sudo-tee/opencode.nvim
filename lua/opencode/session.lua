local M = {}

---@class Session
---@field workspace string
---@field description string
---@field modified number
---@field name string
---@field parentID string|nil
---@field path string
---@field messages_path string
---@field parts_path string
---@field snapshot_path string

---@param dir string Directory path to read JSON files from
---@return table[]|nil Array of decoded JSON objects
function M.read_json_dir(dir)
  if not dir or vim.fn.isdirectory(dir) == 0 then
    return nil
  end

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
  end

  if #decoded_items == 0 then
    return nil
  end
  return decoded_items
end

function M.workspace_slug(path)
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
  return home .. '.local/share/opencode/project/' .. workspace .. '/snapshot/'
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

  return vim.tbl_map(function(session)
    return {
      workspace = vim.fn.getcwd(),
      description = session.title or '',
      modified = session.time.updated,
      name = session.id,
      parentID = session.parentID,
      path = sessions_dir .. '/info/' .. session.id .. '.json',
      messages_path = sessions_dir .. '/message/' .. session.id,
      parts_path = sessions_dir .. '/part/' .. session.id .. '/',
      snapshot_path = M.get_workspace_snapshot_path() .. session.id .. '/',
    }
  end, sessions)
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
  return main_sessions[1]
end

---@param name string
---@return Session|nil
function M.get_by_name(name)
  local sessions = M.get_all_sessions()
  if not sessions then
    return nil
  end

  for _, session in ipairs(sessions) do
    if session.name == name then
      return session
    end
  end

  return nil
end

function M.get_messages(session)
  if not session then
    return nil
  end

  local messages = M.read_json_dir(session.messages_path)
  if not messages then
    return nil
  end

  for _, message in ipairs(messages) do
    if not message.parts or #message.parts == 0 then
      message.parts = M.get_message_parts(message, session)
    end
  end

  return messages
end

function M.get_message_parts(message, session)
  local parts_path = session.parts_path .. message.id
  return M.read_json_dir(parts_path)
end

return M
