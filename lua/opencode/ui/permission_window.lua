local state = require('opencode.state')
local config = require('opencode.config')

local M = {}

-- Simple state
M._permission_queue = {}
M._selected_index = 1

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

  -- Get focus-aware keys
  local keys
  if require('opencode.ui.ui').is_opencode_focused() then
    keys = {
      accept = config.keymap.permission.accept,
      accept_all = config.keymap.permission.accept_all,
      deny = config.keymap.permission.deny,
    }
  else
    keys = {
      accept = config.get_key_for_function('editor', 'permission_accept'),
      accept_all = config.get_key_for_function('editor', 'permission_accept_all'),
      deny = config.get_key_for_function('editor', 'permission_deny'),
    }
  end

  for i, permission in ipairs(M._permission_queue) do
    table.insert(lines, '')
    table.insert(lines, '> [!WARNING] Permission Required')
    table.insert(lines, '>')

    local title = permission.title or table.concat(permission.patterns or {}, ', ') or 'Unknown Permission'
    table.insert(lines, '>  `' .. title .. '`')
    table.insert(lines, '>')

    if keys then
      local actions = {}
      for action, key in pairs(keys) do
        if key then
          local action_label = action == 'accept' and 'accept'
            or action == 'accept_all' and 'Always'
            or action == 'deny' and 'deny'
            or action

          if #M._permission_queue > 1 then
            table.insert(actions, string.format('`%s%d` %s', key, i, action_label))
          else
            table.insert(actions, string.format('`%s` %s', key, action_label))
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

---Setup keymaps for the output buffer when permissions are shown
---@param buf integer Output buffer ID
function M.setup_keymaps(buf)
  if not buf or #M._permission_queue == 0 then
    return
  end

  local api = require('opencode.api')

  -- Get focus-aware keys
  local keys
  local is_opencode_focused = require('opencode.ui.ui').is_opencode_focused()

  if is_opencode_focused then
    keys = {
      accept = config.keymap.permission.accept,
      accept_all = config.keymap.permission.accept_all,
      deny = config.keymap.permission.deny,
    }
  else
    keys = {
      accept = config.get_key_for_function('editor', 'permission_accept'),
      accept_all = config.get_key_for_function('editor', 'permission_accept_all'),
      deny = config.get_key_for_function('editor', 'permission_deny'),
    }
  end

  if keys then
    -- For each permission, create keymaps with letter+number format (for multiple) or just letter (for single)
    for i, permission in ipairs(M._permission_queue) do
      for action, key in pairs(keys) do
        local api_func = api['permission_' .. action]
        if key and api_func then
          -- Create keymap for this specific permission
          local function execute_action()
            M._selected_index = i
            api_func()
            M.remove_permission(permission.id)
          end

          -- For multiple permissions, use key+index format; for single permission, use just key
          local keymap_opts = {
            silent = true,
            desc = string.format('Permission %s: %s', #M._permission_queue > 1 and i or '', action),
          }

          -- Only add buffer restriction for OpenCode-focused keys, not editor keys
          if is_opencode_focused then
            keymap_opts.buffer = buf
          end

          if #M._permission_queue > 1 then
            local keymap = key .. tostring(i)
            vim.keymap.set('n', keymap, execute_action, keymap_opts)
          else
            vim.keymap.set('n', key, execute_action, keymap_opts)
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
