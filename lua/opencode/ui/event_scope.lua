local state = require('opencode.state')
local session_scope = require('opencode.ui.session_scope')

local M = {}

local function active_session_id()
  return state.active_session and state.active_session.id
end

---@param session_id string|nil
---@return boolean
local function active_session(session_id)
  if not session_id or session_id == '' then
    return false
  end

  return session_scope.belongs_to_active_session({ sessionID = session_id })
end

---@param properties table|nil
---@return boolean
local function active_session_update(properties)
  local session = properties and properties.info
  return session and session.id and session.id == active_session_id()
end

---@param properties table|nil
---@return boolean
local function active_message(properties)
  local message = properties and properties.info
  return active_session(message and message.sessionID)
end

---@param properties table|nil
---@return boolean
local function active_part(properties)
  local part = properties and properties.part
  if active_session(part and part.sessionID) then
    return true
  end

  -- Task child events may arrive before their parent task part is indexed.
  return part
    and state.active_session
    and part.sessionID
    and part.sessionID ~= ''
    and (part.tool ~= nil or part.type == 'tool')
end

---@param properties table|nil
---@return boolean
local function active_question_reply(properties)
  if not properties or not properties.requestID then
    return false
  end

  return require('opencode.ui.question_window').matches_active_question({
    id = properties.requestID,
  })
end

---@type table<string, fun(properties: table|nil): boolean>
local policies = {
  ['session.updated'] = active_session_update,
  ['session.compacted'] = function(properties)
    return active_session(properties and properties.sessionID)
  end,
  ['session.error'] = function(properties)
    return active_session(properties and properties.sessionID)
  end,
  ['message.updated'] = active_message,
  ['message.removed'] = function(properties)
    return active_session(properties and properties.sessionID)
  end,
  ['message.part.updated'] = active_part,
  ['message.part.removed'] = function(properties)
    return active_session(properties and properties.sessionID)
  end,
  ['permission.updated'] = session_scope.belongs_to_active_session,
  ['permission.asked'] = session_scope.belongs_to_active_session,
  ['permission.replied'] = function(properties)
    return active_session(properties and properties.sessionID)
  end,
  ['question.asked'] = session_scope.belongs_to_active_session,
  ['question.replied'] = active_question_reply,
  ['question.rejected'] = active_question_reply,
  ['file.edited'] = function()
    return true
  end,
  ['file.watcher.updated'] = function()
    return true
  end,
  ['custom.restore_point.created'] = function()
    return true
  end,
  ['custom.emit_events.finished'] = function()
    return true
  end,
}

---@param event_name string
---@return boolean
function M.has_policy(event_name)
  return policies[event_name] ~= nil
end

---@param event_name string
---@param properties table|nil
---@return boolean
function M.should_handle(event_name, properties)
  local policy = policies[event_name]
  if not policy then
    return false
  end

  return policy(properties)
end

local wrappers = {}

---@param event_name string
---@param callback function
---@return function
function M.scoped_callback(event_name, callback)
  wrappers[event_name] = wrappers[event_name] or setmetatable({}, { __mode = 'k' })
  if not wrappers[event_name][callback] then
    wrappers[event_name][callback] = function(properties)
      if M.should_handle(event_name, properties) then
        callback(properties)
      end
    end
  end

  return wrappers[event_name][callback]
end

return M
