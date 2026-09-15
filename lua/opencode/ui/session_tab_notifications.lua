local state = require('opencode.state')
local session_tabs = require('opencode.state.session_tabs')
local config = require('opencode.config')

local M = {}

local subscribed_manager = nil

local function request_key(kind, request_id)
  return kind .. ':' .. request_id
end

local function session_title(runtime)
  local title = runtime.active_session and runtime.active_session.title
  if type(title) ~= 'string' or vim.trim(title) == '' then
    return 'New session'
  end
  return title
end

local function track(kind, request)
  if not request or not request.id or not request.sessionID then
    return
  end

  local runtime = session_tabs.find_by_session_id(request.sessionID)
  if not runtime then
    return
  end

  if kind == 'permission' then
    session_tabs.add_pending_permission(runtime.id, request)
  else
    session_tabs.add_pending_question(runtime.id, request)
  end

  if runtime.id == session_tabs.active_id() then
    return
  end

  if config.ui.notify_on_background_prompt == false then
    return
  end

  local key = request_key(kind, request.id)
  runtime.background_notifications = runtime.background_notifications or {}
  if runtime.background_notifications[key] then
    return
  end
  runtime.background_notifications[key] = true

  local label = kind == 'permission' and 'Permission required' or 'Question waiting'
  local level = kind == 'permission' and vim.log.levels.WARN or vim.log.levels.INFO
  vim.notify(label .. ' in session "' .. session_title(runtime) .. '"', level)
end

local function clear(kind, request_id)
  if not request_id then
    return
  end

  local tabs = session_tabs.list()
  for _, runtime in ipairs(tabs) do
    if kind == 'permission' then
      session_tabs.remove_pending_permission(runtime.id, request_id)
    else
      session_tabs.remove_pending_question(runtime.id, request_id)
    end
  end
  local key = request_key(kind, request_id)
  for _, runtime in ipairs(tabs) do
    if runtime.background_notifications then
      runtime.background_notifications[key] = nil
    end
  end
end

---@param permission OpencodePermission
function M.track_permission(permission)
  track('permission', permission)
end

---@param question OpencodeQuestionRequest
function M.track_question(question)
  track('question', question)
end

---@param request_id string
function M.clear_permission(request_id)
  clear('permission', request_id)
end

---@param request_id string
function M.clear_question(request_id)
  clear('question', request_id)
end

local function on_permission_updated(permission)
  M.track_permission(permission)
end

local function on_question_asked(question)
  M.track_question(question)
end

local function on_permission_replied(properties)
  M.clear_permission(properties and (properties.permissionID or properties.requestID))
end

local function on_question_replied(properties)
  M.clear_question(properties and properties.requestID)
end

function M.setup()
  local manager = state.event_manager
  if not manager or manager == subscribed_manager then
    return
  end

  if subscribed_manager then
    subscribed_manager:unsubscribe('permission.updated', on_permission_updated)
    subscribed_manager:unsubscribe('permission.asked', on_permission_updated)
    subscribed_manager:unsubscribe('permission.replied', on_permission_replied)
    subscribed_manager:unsubscribe('question.asked', on_question_asked)
    subscribed_manager:unsubscribe('question.replied', on_question_replied)
    subscribed_manager:unsubscribe('question.rejected', on_question_replied)
  end

  manager:subscribe('permission.updated', on_permission_updated)
  manager:subscribe('permission.asked', on_permission_updated)
  manager:subscribe('permission.replied', on_permission_replied)
  manager:subscribe('question.asked', on_question_asked)
  manager:subscribe('question.replied', on_question_replied)
  manager:subscribe('question.rejected', on_question_replied)
  subscribed_manager = manager
end

function M.reset()
  for _, runtime in ipairs(session_tabs.list()) do
    runtime.background_notifications = {}
  end
end

return M
