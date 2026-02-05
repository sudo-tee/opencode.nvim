local state = require('opencode.state')
local Dialog = require('opencode.ui.dialog')

local M = {}

-- Simple state
M._permission_queue = {}
M._dialog = nil
M._processing = false

---Add permission to queue
---@param permission OpencodePermission
function M.add_permission(permission)
  if not permission or not permission.id then
    return
  end

  -- Update if exists, otherwise add
  for i, existing in ipairs(M._permission_queue) do
    if existing.id == permission.id then
      M._permission_queue[i] = permission
      M._setup_dialog() -- Refresh dialog when permission is updated
      return
    end
  end

  table.insert(M._permission_queue, permission)
  M._setup_dialog() -- Setup dialog when first permission is added
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
  local formatter = require('opencode.ui.formatter')

  local progress = ''
  if #M._permission_queue > 1 then
    progress = string.format(' (%d/%d)', 1, #M._permission_queue)
  end

  local title = permission.title
    or table.concat(permission.patterns or {}, ', '):gsub('\r', '\\r'):gsub('\n', '\\n')
    or 'Unknown Permission'
  local perm_type = permission.permission or permission.type or 'unknown'

  local content = { (icons.get(perm_type) or '') .. ' *' .. (perm_type or '') .. '*' .. ' `' .. title .. '`' }

  local options = {
    { label = 'Allow once' },
    { label = 'Reject' },
    { label = 'Allow always' },
  }

  local render_content = nil
  if perm_type == 'edit' and permission.metadata and permission.metadata.diff then
    render_content = function(out)
      out:add_line(content[1])
      out:add_line('')

      local file_type = permission.metadata.filepath and vim.fn.fnamemodify(permission.metadata.filepath, ':e') or ''
      formatter.format_diff(out, permission.metadata.diff, file_type)
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
    require('opencode.ui.renderer').render_permissions_display()
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
    require('opencode.ui.renderer').render_permissions_display()
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
end

function M._clear_dialog()
  if M._dialog then
    M._dialog:teardown()
    M._dialog = nil
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
