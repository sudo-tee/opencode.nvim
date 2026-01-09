local state = require('opencode.state')
local config = require('opencode.config')

local M = {}

-- Simple state
M._permission_queue = {}
M._selected_index = 1

---Get focus-aware permission keys
---@return table|nil keys table with accept, accept_all, deny keys
local function get_permission_keys()
  local is_opencode_focused = require('opencode.ui.ui').is_opencode_focused()

  if is_opencode_focused then
    return {
      accept = config.keymap.permission.accept,
      accept_all = config.keymap.permission.accept_all,
      deny = config.keymap.permission.deny,
    }
  else
    return {
      accept = config.get_key_for_function('editor', 'permission_accept'),
      accept_all = config.get_key_for_function('editor', 'permission_accept_all'),
      deny = config.get_key_for_function('editor', 'permission_deny'),
    }
  end
end

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
      return
    end
  end

  table.insert(M._permission_queue, permission)
end

---Remove permission from queue
---@param permission_id string
function M.remove_permission(permission_id)
  for i, permission in ipairs(M._permission_queue) do
    if permission.id == permission_id then
      table.remove(M._permission_queue, i)
      if M._selected_index > #M._permission_queue then
        M._selected_index = math.max(1, #M._permission_queue)
      end
      return
    end
  end
  if #M._permission_queue == 0 then
    M.clear_keymaps()
  end
end

---Select next permission
function M.select_next()
  if #M._permission_queue > 1 then
    M._selected_index = M._selected_index % #M._permission_queue + 1
  end
end

---Select previous permission
function M.select_prev()
  if #M._permission_queue > 1 then
    M._selected_index = M._selected_index == 1 and #M._permission_queue or M._selected_index - 1
  end
end

---Get currently selected permission
---@return OpencodePermission|nil
function M.get_current_permission()
  if M._selected_index > 0 and M._selected_index <= #M._permission_queue then
    return M._permission_queue[M._selected_index]
  end
  return nil
end

---Get permission display lines to append to output
---@return string[]
function M.get_display_lines()
  if #M._permission_queue == 0 then
    return {}
  end

  local lines = {}

  local keys = get_permission_keys()

  M.setup_keymaps()

  for i, permission in ipairs(M._permission_queue) do
    table.insert(lines, '')
    table.insert(lines, '> [!WARNING] Permission Required')
    table.insert(lines, '>')

    local title = permission.title or table.concat(permission.patterns or {}, ', ') or 'Unknown Permission'
    table.insert(lines, '>  `' .. title .. '`')
    table.insert(lines, '>')

    if keys then
      local actions = {}
      local action_order = { 'accept', 'deny', 'accept_all' }

      for _, action in ipairs(action_order) do
        local key = keys[action]
        if key then
          local action_label = action == 'accept' and 'Accept'
            or action == 'accept_all' and 'Always'
            or action == 'deny' and 'Deny'
            or action

          if #M._permission_queue > 1 then
            table.insert(actions, string.format('%s `%s%d`', action_label, key, i))
          else
            table.insert(actions, string.format('%s `%s`', action_label, key))
          end
        end
      end
      if #actions > 0 then
        table.insert(lines, '> ' .. table.concat(actions, '   '))
      end
    end

    if i < #M._permission_queue then
      table.insert(lines, '>')
    end
  end

  table.insert(lines, '')

  return lines
end

function M.clear_keymaps()
  if #M._permission_queue == 0 then
    return
  end

  local buffers = { state.windows and state.windows.input_buf, state.windows and state.windows.output_buf }
  local opencode_keys = {
    accept = config.keymap.permission.accept,
    accept_all = config.keymap.permission.accept_all,
    deny = config.keymap.permission.deny,
  }

  local editor_keys = {
    accept = config.get_key_for_function('editor', 'permission_accept'),
    accept_all = config.get_key_for_function('editor', 'permission_accept_all'),
    deny = config.get_key_for_function('editor', 'permission_deny'),
  }

  local action_order = { 'accept', 'deny', 'accept_all' }

  for i, permission in ipairs(M._permission_queue) do
    for _, action in ipairs(action_order) do
      -- Clear OpenCode-focused keys (buffer-specific)
      local opencode_key = opencode_keys[action]
      if opencode_key then
        local function safe_del(keymap, opts)
          pcall(vim.keymap.del, 'n', keymap, opts)
        end

        for _, buf in ipairs(buffers) do
          if buf then
            if #M._permission_queue > 1 then
              safe_del(opencode_key .. tostring(i), { buffer = buf })
            else
              safe_del(opencode_key, { buffer = buf })
            end
          end
        end
      end

      local editor_key = editor_keys[action]
      if editor_key then
        local function safe_del_global(keymap)
          pcall(vim.keymap.del, 'n', keymap)
        end

        if #M._permission_queue > 1 then
          safe_del_global(editor_key .. tostring(i))
        else
          safe_del_global(editor_key)
        end
      end
    end
  end
end

---Setup keymaps for all permission actions
function M.setup_keymaps()
  M.clear_keymaps()
  if #M._permission_queue == 0 then
    return
  end

  local buffers = { state.windows and state.windows.input_buf, state.windows and state.windows.output_buf }
  local api = require('opencode.api')

  local opencode_keys = {
    accept = config.keymap.permission.accept,
    accept_all = config.keymap.permission.accept_all,
    deny = config.keymap.permission.deny,
  }

  local editor_keys = {
    accept = config.get_key_for_function('editor', 'permission_accept'),
    accept_all = config.get_key_for_function('editor', 'permission_accept_all'),
    deny = config.get_key_for_function('editor', 'permission_deny'),
  }

  local action_order = { 'accept', 'deny', 'accept_all' }

  for i, permission in ipairs(M._permission_queue) do
    for _, action in ipairs(action_order) do
      local api_func = api['permission_' .. action]
      if api_func then
        local function execute_action()
          M._selected_index = i
          api_func()
          M.remove_permission(permission.id)
        end

        local opencode_key = opencode_keys[action]
        if opencode_key then
          local keymap_opts = {
            silent = true,
            desc = string.format('Permission %s: %s', #M._permission_queue > 1 and i or '', action),
          }

          for _, buf in ipairs(buffers) do
            if buf then
              local buffer_opts = vim.tbl_extend('force', keymap_opts, { buffer = buf })

              if #M._permission_queue > 1 then
                vim.keymap.set('n', opencode_key .. tostring(i), execute_action, buffer_opts)
              else
                vim.keymap.set('n', opencode_key, execute_action, buffer_opts)
              end
            end
          end
        end

        local editor_key = editor_keys[action]
        if editor_key then
          local global_opts = {
            silent = true,
            desc = string.format('Permission %s: %s (global)', #M._permission_queue > 1 and i or '', action),
          }

          if #M._permission_queue > 1 then
            vim.keymap.set('n', editor_key .. tostring(i), execute_action, global_opts)
          else
            vim.keymap.set('n', editor_key, execute_action, global_opts)
          end
        end
      end
    end
  end
end

---Check if we have permissions
---@return boolean
function M.has_permissions()
  return #M._permission_queue > 0
end

---Clear all permissions
function M.clear_all()
  M._permission_queue = {}
  M._selected_index = 1
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
