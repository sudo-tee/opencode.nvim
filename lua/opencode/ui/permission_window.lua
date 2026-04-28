local state = require('opencode.state')
local Dialog = require('opencode.ui.dialog')

local M = {}

-- Simple state
M._permission_queue = {}
M._dialog = nil
M._processing = false

---Get the tool identifiers from a permission (nested or root-level).
---@param permission OpencodePermission|nil
---@return string|nil call_id
---@return string|nil message_id
local function get_tool_ids(permission)
  if not permission then
    return nil, nil
  end
  local tool = permission.tool
  local call_id = (tool and tool.callID) or permission.callID
  local message_id = (tool and tool.messageID) or permission.messageID
  return call_id, message_id
end

---Find the message part that corresponds to a permission request.
---@param permission OpencodePermission|nil
---@return OpencodeMessagePart|nil
local function get_permission_part(permission)
  local call_id, message_id = get_tool_ids(permission)
  if not message_id or message_id == '' then
    return nil
  end

  if state.messages then
    for _, message in ipairs(state.messages) do
      if message.info and message.info.id == message_id then
        for _, part in ipairs(message.parts or {}) do
          if call_id and call_id ~= '' then
            if part.callID == call_id then
              return part
            end
          else
            return part
          end
        end
      end
    end
  end

  if permission and permission.sessionID and permission.sessionID ~= '' then
    local render_state = require('opencode.ui.renderer.ctx').render_state
    for _, part in ipairs(render_state:get_child_session_parts(permission.sessionID) or {}) do
      if call_id and call_id ~= '' then
        if part.callID == call_id then
          return part
        end
      else
        return part
      end
    end
  end
end

---Check whether a permission has already been resolved (completed, error, etc.)
---by inspecting the corresponding message part's status.
---@param permission OpencodePermission|nil
---@return boolean
local function is_resolved_permission(permission)
  local part = get_permission_part(permission)
  if not part or not part.state then
    return false
  end

  local part_status = part.state.status
  return part_status ~= nil and part_status ~= '' and part_status ~= 'pending' and part_status ~= 'running'
end

---Add permission to queue
---@param permission OpencodePermission
function M.add_permission(permission)
  if not permission or not permission.id then
    return
  end

  if permission.tool then
    permission._message_id = permission.tool.messageID
    permission._call_id = permission.tool.callID
  end

  -- Update if exists, otherwise add
  for i, existing in ipairs(M._permission_queue) do
    if existing.id == permission.id then
      M._permission_queue[i] = permission
      M._setup_dialog()
      return
    end
  end

  table.insert(M._permission_queue, permission)
  M._setup_dialog()
end

---Update permission from message part data
---@param permission_id string
---@param part table
---@return boolean
function M.update_permission_from_part(permission_id, part)
  if not permission_id or not part then
    return false
  end

  local permission = nil
  for i, existing in ipairs(M._permission_queue) do
    if existing.id == permission_id then
      permission = existing
      break
    end
  end

  if not permission then
    return false
  end

  if part.state and part.state.input then
    local input = part.state.input
    local updated = false

    if input.description and input.description ~= '' then
      permission._description = input.description
      updated = true
    end

    if input.command and input.command ~= '' then
      permission._command = input.command
      updated = true
    end

    if updated and M._dialog then
      M._setup_dialog()
    end

    return true
  end

  return false
end

---Remove permission from queue
---@param permission_id string
function M.remove_permission(permission_id)
  for i, permission in ipairs(M._permission_queue) do
    if permission.id == permission_id then
      table.remove(M._permission_queue, i)
      break
    end
  end

  if #M._permission_queue == 0 then
    M._clear_dialog()
  else
    M._setup_dialog() -- Setup dialog for next permission
  end
end

---Get currently selected permission (always the first one now)
---@return OpencodePermission|nil
function M.get_current_permission()
  return M._permission_queue[1]
end

---Get permission display lines to append to output
---@param output Output
function M.format_display(output)
  if #M._permission_queue == 0 or not M._dialog or M._processing then
    return
  end

  local permission = M._permission_queue[1]
  if not permission then
    return
  end

  local icons = require('opencode.ui.icons')
  local formatter_utils = require('opencode.ui.formatter.utils')

  local progress = ''
  if #M._permission_queue > 1 then
    progress = string.format(' (%d/%d)', 1, #M._permission_queue)
  end

  local content = {}
  local perm_type = permission.permission or permission.type or ''

  if permission._description and permission._description ~= '' then
    table.insert(content, (icons.get(perm_type)) .. ' *' .. perm_type .. '* ' .. permission._description)
  elseif permission.title then
    table.insert(content, (icons.get(perm_type)) .. ' *' .. perm_type .. '* `' .. permission.title .. '`')
  else
    table.insert(content, (icons.get(perm_type)) .. ' *' .. perm_type .. '*')
    table.insert(content, string.format('```%s', perm_type))
    for _, pattern in ipairs(permission.patterns or {}) do
      for _, line in ipairs(vim.split(pattern, '\n')) do
        table.insert(content, line)
      end
    end
    table.insert(content, '```')
  end

  table.insert(content, '')

  if permission._command and permission._command ~= '' then
    local lines = vim.split(permission._command, '\n')
    table.insert(content, string.format('```%s', perm_type))
    for _, line in ipairs(lines) do
      table.insert(content, line)
    end
    table.insert(content, '```')
  end

  local options = {
    { label = 'Allow once' },
    { label = 'Reject' },
    { label = 'Allow always' },
  }

  local render_content = nil
  if perm_type == 'edit' and permission.metadata and permission.metadata.diff then
    render_content = function(out)
      out:add_line(content[1])
      if content[2] then
        out:add_line(content[2])
      end
      out:add_line('')

      local file_type = permission.metadata.filepath and vim.fn.fnamemodify(permission.metadata.filepath, ':e') or ''
      formatter_utils.format_diff(out, permission.metadata.diff, file_type)
    end
  end

  M._dialog:format_dialog(output, {
    title = icons.get('warning') .. ' Permission Required' .. progress,
    title_hl = 'OpencodePermissionTitle',
    border_hl = 'OpencodePermissionBorder',
    content = render_content and nil or content,
    render_content = render_content,
    options = options,
    unfocused_message = 'Focus Opencode window to respond to permission',
  })
end

function M._setup_dialog()
  if #M._permission_queue == 0 then
    M._clear_dialog()
    return
  end

  local saved_selection = nil
  if M._dialog then
    saved_selection = M._dialog:get_selection()
  end

  M._clear_dialog()

  if not state.windows or not state.windows.output_buf then
    return
  end

  local buf = state.windows.output_buf

  local function check_focused()
    local ui = require('opencode.ui.ui')
    return ui.is_opencode_focused() and #M._permission_queue > 0
  end

  local function on_select(index)
    if not check_focused() then
      return
    end

    local permission = M.get_current_permission()
    if not permission then
      return
    end

    M._processing = true
    require('opencode.ui.renderer.events').render_permissions_display()
    M._clear_dialog()

    local api = require('opencode.api')
    local actions = { 'accept', 'deny', 'accept_all' }
    local action = actions[index]

    vim.defer_fn(function()
      if action then
        local api_func = api['permission_' .. action]
        if api_func then
          api_func(permission)
        end
      end
      M.remove_permission(permission.id)
      M._processing = false
    end, 50)
  end

  local function on_navigate()
    require('opencode.ui.renderer.events').render_permissions_display()
  end

  local function get_option_count()
    return #M._permission_queue > 0 and 3 or 0 -- accept, deny, accept_all
  end

  M._dialog = Dialog.new({
    buffer = buf,
    on_select = on_select,
    on_navigate = on_navigate,
    get_option_count = get_option_count,
    check_focused = check_focused,
    namespace_prefix = 'opencode_permission',
    keymaps = {
      dismiss = '', -- Disable dismiss keymap and legend
    },
  })

  M._dialog:setup()

  if saved_selection then
    M._dialog:set_selection(saved_selection)
  end
end

function M._clear_dialog()
  if M._dialog then
    M._dialog:teardown()
    M._dialog = nil
  end
end

---Query the server for pending permissions and restore any that belong
---to the active session.  Mirrors question_window.restore_pending_question.
---@param session_id string|nil
function M.restore_pending_permissions(session_id)
  local Promise = require('opencode.promise')
  if not state.api_client or not session_id or session_id == '' then
    return Promise.new():resolve(nil)
  end

  return state.api_client:list_permissions()
    :and_then(function(permissions)
      if not permissions or type(permissions) ~= 'table' then
        return
      end

      local events = require('opencode.ui.renderer.events')
      local render_state = require('opencode.ui.renderer.ctx').render_state

      for _, permission in ipairs(permissions) do
        if permission and permission.id then
          -- Check if this permission belongs to the active session or
          -- one of its child sessions (task tool).
          local belongs = permission.sessionID == session_id
          if not belongs and permission.sessionID and permission.sessionID ~= '' then
            belongs = render_state:get_task_part_by_child_session(permission.sessionID) ~= nil
          end
          if not belongs then
            local tool = permission.tool
            local tool_message_id = tool and tool.messageID
            if tool_message_id and state.messages then
              for _, message in ipairs(state.messages) do
                if message.info and message.info.id == tool_message_id then
                  belongs = true
                  break
                end
              end
            end
          end

          if belongs and not is_resolved_permission(permission) then
            -- Check if already queued (avoid duplicate)
            local already_queued = false
            for _, existing in ipairs(M._permission_queue) do
              if existing.id == permission.id then
                already_queued = true
                break
              end
            end
            if not already_queued then
              events.on_permission_updated(permission)
            end
          end
        end
      end
    end)
    :catch(function(err)
      vim.schedule(function()
        vim.notify('Failed to restore pending permissions: ' .. vim.inspect(err), vim.log.levels.WARN)
      end)
    end)
end

---Check if we have permissions
---@return boolean
function M.has_permissions()
  return #M._permission_queue > 0
end

---Clear all permissions
function M.clear_all()
  M._clear_dialog()
  M._permission_queue = {}
end

---Get all permissions
---@return OpencodePermission[]
function M.get_all_permissions()
  return M._permission_queue
end

---Get permission count
---@return integer
function M.get_permission_count()
  return #M._permission_queue
end

return M
