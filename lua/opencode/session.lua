local M = {}

---@class Session
---@field workspace string
---@field description string
---@field modified number
---@field name string
---@field path string
---@field messages_path string

function M.workspace_slug()
  local workspace = vim.fn.getcwd()
  local separator = package.config:sub(1, 1) -- Get the path separator (either "/" or "\")
  return workspace:gsub(separator, '-'):gsub('%.', '-'):sub(2)
end

function M.get_workspace_session_path(workspace)
  workspace = workspace or M.workspace_slug()
  return vim.fn.expand('$HOME/.local/share/opencode/project/' .. workspace .. '/storage/session')
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
      path = sessions_dir .. '/info/' .. session.id .. '.json',
      messages_path = sessions_dir .. '/message/' .. session.id,
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
  return sessions[1]
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

  local messages_path = session.messages_path
  if not messages_path or vim.fn.isdirectory(messages_path) == 0 then
    return nil
  end
  local decoded_messages = {}

  for file, type_ in vim.fs.dir(messages_path) do
    if type_ == 'file' then
      local content = table.concat(vim.fn.readfile(messages_path .. '/' .. file), '\n')

      local ok, message = pcall(vim.json.decode, content)
      if ok and message then
        table.insert(decoded_messages, message)
      end
    end
  end

  return decoded_messages
end

return M
