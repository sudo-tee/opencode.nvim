local session_tabs = require('opencode.state.session_tabs')
local config = require('opencode.config')

local M = {}

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
  local session_id = request and (request.sessionID or request.session_id)
  if not request or not request.id or not session_id then
    return
  end

  local runtime = session_tabs.find_by_session_id(session_id)
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

  local tabs = session_tabs.all()
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

function M.setup()
  local group = vim.api.nvim_create_augroup('OpencodeSessionTabNotifications', { clear = true })
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = {
      'OpencodeEvent:permission.updated',
      'OpencodeEvent:permission.asked',
      'OpencodeEvent:permission.replied',
      'OpencodeEvent:question.asked',
      'OpencodeEvent:question.replied',
      'OpencodeEvent:question.rejected',
      'OpencodeEvent:form.created',
      'OpencodeEvent:form.replied',
      'OpencodeEvent:form.cancelled',
    },
    callback = function(args)
      local event = args.data and args.data.event
      if not event then
        return
      end

      local properties = event.properties
      if event.type == 'permission.updated' or event.type == 'permission.asked' then
        M.track_permission(properties)
      elseif event.type == 'permission.replied' then
        M.clear_permission(properties and (properties.permissionID or properties.requestID))
      elseif event.type == 'question.asked' then
        M.track_question(properties)
      elseif event.type == 'form.created' then
        M.track_question(properties and properties.form)
      elseif
        event.type == 'question.replied'
        or event.type == 'question.rejected'
        or event.type == 'form.replied'
        or event.type == 'form.cancelled'
      then
        M.clear_question(properties and (properties.requestID or properties.id))
      end
    end,
  })
end

function M.reset()
  for _, runtime in ipairs(session_tabs.all()) do
    runtime.background_notifications = {}
  end
end

return M
