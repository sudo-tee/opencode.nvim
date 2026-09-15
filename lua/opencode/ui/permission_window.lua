local state = require('opencode.state')
local session_tabs = require('opencode.state.session_tabs')
local Dialog = require('opencode.ui.dialog')
local formatter_utils = require('opencode.ui.formatter.utils')

local M = {}

-- Simple state
M._permission_queue = {}
M._dialog = nil
M._processing = false
M._interaction = nil
M._observations = {}

local function is_current_permission(permission_id)
  local permission = M._permission_queue[1]
  return permission ~= nil and permission.id == permission_id
end

local function stop_timer(timer)
  timer:stop()
  timer:close()
end

local function clear_interaction()
  local interaction = M._interaction
  M._interaction = nil
  if not interaction then
    return
  end

  M._processing = false
  if interaction.timer then
    stop_timer(interaction.timer)
  end
  if interaction.feedback then
    interaction.feedback.close()
  end
end

local function interaction_for(permission)
  if M._interaction and M._interaction.permission_id == permission.id then
    return M._interaction
  end

  clear_interaction()
  M._interaction = {
    permission_id = permission.id,
    deny_armed = false,
    timer = nil,
    feedback = nil,
  }
  return M._interaction
end

local function clear_deny_timer(interaction)
  interaction.deny_armed = false
  if interaction.timer then
    stop_timer(interaction.timer)
    interaction.timer = nil
  end
end

---@param permission table|nil
---@return string|nil
local function get_child_session_id(permission)
  local session_id = permission and permission.session_id
  local active_session = state.active_session
  if not session_id or session_id == '' or (active_session and active_session.id == session_id) then
    return nil
  end

  local render_state = require('opencode.ui.renderer.ctx').render_state
  return render_state:get_task_part_by_child_session(session_id) and session_id or nil
end

---Add permission to queue
---@param permission table
function M.add_permission(permission)
  if not permission or not permission.id then
    return
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

---Remove permission from queue
---@param permission_id string
function M.remove_permission(permission_id)
  if M._interaction and M._interaction.permission_id == permission_id then
    clear_interaction()
  end

  for i, permission in ipairs(M._permission_queue) do
    if permission.id == permission_id then
      local runtime = session_tabs.find_by_session_id(permission.sessionID)
      if runtime then
        session_tabs.remove_pending_permission(runtime.id, permission_id)
      end
      table.remove(M._permission_queue, i)
      break
    end
  end
  M._observations[permission_id] = nil

  if #M._permission_queue == 0 then
    M._clear_dialog()
  else
    M._setup_dialog() -- Setup dialog for next permission
  end

  require('opencode.ui.renderer').refresh_prompts()
end

---Get currently selected permission (always the first one now)
---@return table|nil
function M.get_current_permission()
  return M._permission_queue[1]
end

---Get permission display lines to append to output
---@param output Output
function M.format_display(output)
  if #M._permission_queue == 0 or not M._dialog then
    return
  end

  local permission = M._permission_queue[1]
  if not permission then
    return
  end

  local icons = require('opencode.ui.icons')
  local dialog_start_line = output:get_line_count()

  local progress = ''
  if #M._permission_queue > 1 then
    progress = string.format(' (%d/%d)', 1, #M._permission_queue)
  end

  local content = {}
  local perm_type = permission.permission or permission.action or ''
  local description = permission.message
  local patterns = permission.patterns or permission.resources or {}

  if description and description ~= '' then
    table.insert(content, (icons.get(perm_type)) .. ' *' .. perm_type .. '* ' .. description)
  else
    table.insert(content, (icons.get(perm_type)) .. ' *' .. perm_type .. '*')
    table.insert(content, string.format('```%s', perm_type))
    for _, pattern in ipairs(patterns) do
      pattern = type(pattern) == 'string' and pattern or vim.inspect(pattern)
      for _, line in ipairs(vim.split(pattern, '\n')) do
        table.insert(content, line)
      end
    end
    table.insert(content, '```')
  end

  table.insert(content, '')

  local options = {
    { label = 'Allow once' },
    { label = 'Reject' },
    { label = 'Allow always' },
  }

  local interaction = interaction_for(permission)
  local legend_lines = interaction.deny_armed and { 'Release `Esc` to cancel, press again to deny' }
    or { 'Double `Esc` to deny and stop' }

  M._dialog:format_dialog(output, {
    title = icons.get('warning') .. ' Permission Required' .. progress,
    title_hl = 'OpencodePermissionTitle',
    border_hl = 'OpencodePermissionBorder',
    content = content,
    options = options,
    unfocused_message = 'Focus Opencode window to respond to permission',
    legend_lines = legend_lines,
  })

  local child_session_id = get_child_session_id(permission)
  if child_session_id then
    output:add_action({
      text = '[S] Open this Session',
      type = 'navigate_session_tree',
      args = formatter_utils.get_session_action_args(child_session_id),
      key = 'S',
      display_line = dialog_start_line,
      range = { from = dialog_start_line, to = math.max(dialog_start_line, output:get_line_count() - 1) },
    })
  end
end

---@param permission table
---@param choice 'once'|'always'|'reject'
---@param message? string
function M.reply(permission, choice, message)
  local observation = permission and M._observations[permission.id]
  if not observation or not permission or permission.status ~= 'pending' then
    error('permission request is not pending')
  end
  return observation
    :reply_permission(permission.id, { choice = choice, message = message })
    :and_then(function(result)
      M.remove_permission(permission.id)
      return result
    end)
    :catch(function(err)
      M._processing = false
      vim.schedule(function()
        vim.notify('Failed to reply to permission: ' .. vim.inspect(err), vim.log.levels.ERROR)
      end)
      error(err, 0)
    end)
end

function M._setup_dialog()
  if #M._permission_queue == 0 then
    M._clear_dialog()
    return
  end

  local current_permission = M.get_current_permission()
  local interaction = interaction_for(current_permission)

  local saved_selection = nil
  if M._dialog then
    saved_selection = M._dialog:get_selection()
  end

  M._clear_dialog(true)

  if not state.windows or not state.windows.output_buf then
    return
  end

  local buf = state.windows.output_buf

  local function check_focused()
    local ui = require('opencode.ui.ui')
    return ui.is_opencode_focused() and #M._permission_queue > 0
  end

  local function is_active_permission(permission_id)
    return M._processing and is_current_permission(permission_id) and M._interaction == interaction
  end

  local function on_select(index)
    if M._processing then
      return
    end

    if not check_focused() then
      return
    end

    local permission = M.get_current_permission()
    if not permission then
      return
    end

    local permission_id = permission.id
    if not is_current_permission(permission_id) or M._interaction ~= interaction then
      return
    end

    local choices = { 'once', 'reject', 'always' }
    local choice = choices[index]
    if not choice then
      return
    end

    M._processing = true

    vim.schedule(function()
      if not is_active_permission(permission_id) then
        return
      end

      if choice == 'reject' then
        local pos = M._dialog and M._dialog:get_option_position(index)
        local part_data = require('opencode.ui.renderer.ctx').render_state:get_part('permission-display-part')
        local output_win = state.windows and state.windows.output_win

        if output_win and vim.api.nvim_win_is_valid(output_win) then
          clear_deny_timer(interaction)
          local cursor = vim.api.nvim_win_get_cursor(output_win)
          local row = part_data and part_data.line_start and pos and (part_data.line_start + pos.line)
            or math.max(0, cursor[1] - 1)
          local col = pos and pos.col or 0
          interaction.feedback = require('opencode.ui.inline_input').open({
            win = output_win,
            row = row,
            col = col,
            title = 'Tell OpenCode what to do differently',
            on_submit = function(text)
              if not is_active_permission(permission_id) then
                return
              end
              interaction.feedback = nil
              M.reply(permission, choice, (text ~= '') and text or nil)
            end,
            on_cancel = function()
              if M._interaction == interaction then
                interaction.feedback = nil
                clear_deny_timer(interaction)
                M._processing = false
              end
            end,
          })
        else
          clear_deny_timer(interaction)
          M._processing = false
          vim.notify('Cannot open permission feedback without an output window', vim.log.levels.ERROR)
        end
      else
        M.reply(permission, choice)
      end
    end)
  end

  local function on_navigate()
    require('opencode.ui.renderer').refresh_prompts()
  end

  local function get_option_count()
    return #M._permission_queue > 0 and 3 or 0 -- accept, deny, accept_all
  end

  M._dialog = Dialog.new({
    buffer = buf,
    on_select = on_select,
    on_dismiss = function()
      if M._processing or not check_focused() or not is_current_permission(interaction.permission_id) then
        return
      end

      if interaction.deny_armed then
        clear_deny_timer(interaction)
        M._processing = true
        M.reply(current_permission, 'reject')
        return
      end

      interaction.deny_armed = true
      require('opencode.ui.renderer').refresh_prompts()
      local timer
      timer = vim.defer_fn(function()
        if M._interaction == interaction and interaction.timer == timer then
          interaction.deny_armed = false
          interaction.timer = nil
          require('opencode.ui.renderer').refresh_prompts()
        end
      end, 2000)
      interaction.timer = timer
    end,
    on_navigate = on_navigate,
    get_option_count = get_option_count,
    check_focused = check_focused,
    namespace_prefix = 'opencode_permission',
    show_dismiss_legend = false,
    keymaps = {
      dismiss = '<Esc>',
    },
  })

  M._dialog:setup()

  if saved_selection then
    M._dialog:set_selection(saved_selection)
  end
end

---@param preserve_interaction? boolean
function M._clear_dialog(preserve_interaction)
  if M._dialog then
    M._dialog:teardown()
    M._dialog = nil
  end
  if not preserve_interaction then
    clear_interaction()
  end
end

---@param observations table[]
function M.sync(observations)
  local pending = {}
  local owners = {}
  for _, observation in ipairs(observations or {}) do
    for _, request in pairs(observation:read().permission_requests_by_id or {}) do
      if request.status == 'pending' then
        pending[#pending + 1] = request
        owners[request.id] = observation
      end
    end
  end
  table.sort(pending, function(left, right)
    if left.session_id ~= right.session_id then
      return (left.session_id or '') < (right.session_id or '')
    end
    return left.id < right.id
  end)
  M._permission_queue = pending
  M._observations = owners
  if #pending == 0 then
    M._clear_dialog()
  else
    M._setup_dialog()
  end
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
  M._observations = {}
end

---Get all permissions
---@return table[]
function M.get_all_permissions()
  return M._permission_queue
end

---Get permission count
---@return integer
function M.get_permission_count()
  return #M._permission_queue
end

require('opencode.ui.renderer.ctx').prompt_controllers.permission = M

require('opencode.ui.formatter.system').register('permissions-display', function(output)
  M.format_display(output)
end)

return M
