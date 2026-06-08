local state = require('opencode.state')

local M = {}

---@param request table|nil
---@return string|nil
local function get_message_id(request)
  if not request then
    return nil
  end

  local tool = request.tool
  return (tool and tool.messageID) or request.messageID
end

---@param request table|nil
---@param session_id string|nil
---@return boolean
function M.belongs_to_session(request, session_id)
  if not request then
    return false
  end

  if request.sessionID and request.sessionID ~= '' then
    if request.sessionID == session_id then
      return true
    end

    local render_state = require('opencode.ui.renderer.ctx').render_state
    if render_state:get_task_part_by_child_session(request.sessionID) ~= nil then
      return true
    end
  end

  local message_id = get_message_id(request)
  if message_id and state.messages then
    for _, message in ipairs(state.messages) do
      if message.info and message.info.id == message_id then
        return true
      end
    end
  end

  return (not request.sessionID or request.sessionID == '') and session_id ~= nil and session_id ~= ''
end

---@param request table|nil
---@return boolean
function M.belongs_to_active_session(request)
  local active_session = state.active_session
  return M.belongs_to_session(request, active_session and active_session.id)
end

return M
