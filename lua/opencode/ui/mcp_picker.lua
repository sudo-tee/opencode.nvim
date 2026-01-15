local M = {}
local base_picker = require('opencode.ui.base_picker')
local icons = require('opencode.ui.icons')
local Promise = require('opencode.promise')

---Format MCP server item for picker
---@param mcp_item table MCP server definition
---@param width number Window width
---@return PickerItem
local function format_mcp_item(mcp_item, width)
  local is_connected = mcp_item.status == 'connected'
  local is_failed = mcp_item.status == 'failed'
  local status_icon = is_connected and icons.get('status_on') or icons.get('status_off')

  local item_width = width or vim.api.nvim_win_get_width(0)
  local icon_width = vim.api.nvim_strwidth(status_icon) + 1
  local content_width = item_width - icon_width --[[@as number]]

  local icon_highlight
  local name_highlight

  if is_connected then
    icon_highlight = 'OpencodeContextSwitchOn'
    name_highlight = 'OpencodeContextSwitchOn'
  elseif is_failed then
    icon_highlight = 'OpencodeContextError'
    name_highlight = 'OpencodeContextError'
  else
    icon_highlight = 'OpencodeHint'
    name_highlight = 'OpencodeHint'
  end

  return base_picker.create_picker_item({
    { text = base_picker.align(mcp_item.name, content_width, { truncate = true }), highlight = name_highlight },
    { text = base_picker.align(status_icon, icon_width, { align = 'right' }), highlight = icon_highlight },
  })
end

---Show MCP servers picker with connect/disconnect actions
---@param callback function?
function M.pick(callback)
  local state = require('opencode.state')
  local config = require('opencode.config')

  local get_mcp_servers = Promise.async(function()
    local ok, mcp_list = pcall(function()
      return state.api_client:list_mcp_servers():await()
    end)

    if not ok then
      vim.notify('Failed to fetch MCP servers: ' .. tostring(mcp_list), vim.log.levels.ERROR)
      return {}
    end

    if not mcp_list then
      return {}
    end

    local items = {}
    for name, def in pairs(mcp_list) do
      table.insert(items, {
        name = name,
        type = def.type,
        enabled = def.enabled,
        status = def.status or 'disconnected',
        error = def.error,
        command = def.command,
        url = def.url,
      })
    end

    table.sort(items, function(a, b)
      local status_priority = {
        connected = 1,
        failed = 2,
        disabled = 3,
        disconnected = 4,
      }
      local a_priority = status_priority[a.status] or 5
      local b_priority = status_priority[b.status] or 5

      if a_priority ~= b_priority then
        return a_priority < b_priority
      end
      return a.name < b.name
    end)

    return items
  end)

  local initial_items = get_mcp_servers():await()

  if #initial_items == 0 then
    vim.notify('No MCP servers configured', vim.log.levels.WARN)
    return
  end

  -- Shared toggle connection logic
  local toggle_mcp_connection = Promise.async(function(selected)
    if not selected then
      return nil
    end

    local is_connected = selected.status == 'connected'
    local action = is_connected and 'disconnect' or 'connect'

    vim.notify(
      string.format('%s MCP server: %s...', is_connected and 'Disconnecting' or 'Connecting', selected.name),
      vim.log.levels.INFO
    )

    if is_connected then
      state.api_client:disconnect_mcp(selected.name):await()
    else
      state.api_client:connect_mcp(selected.name):await()
    end

    local updated_servers = get_mcp_servers():await()
    local updated_server = vim.tbl_filter(function(s)
      return s.name == selected.name
    end, updated_servers)[1]

    if updated_server then
      local actual_status = updated_server.status
      local succeeded = (action == 'disconnect' and actual_status ~= 'connected')
        or (action == 'connect' and actual_status == 'connected')

      if succeeded then
        vim.notify(
          string.format(
            'Successfully %s MCP server: %s',
            action == 'connect' and 'connected' or 'disconnected',
            updated_server.name
          ),
          vim.log.levels.INFO
        )
      else
        vim.notify(
          string.format(
            'Failed to %s MCP server: %s%s',
            action,
            updated_server.name,
            updated_server.error and (' > ' .. updated_server.error) or ''
          ),
          vim.log.levels.ERROR
        )
      end
    end

    return updated_servers
  end)

  local actions = {
    toggle_connection = {
      key = config.keymap.mcp_picker.toggle_connection,
      label = 'toggle connection',
      fn = Promise.async(function(selected, opts)
        return toggle_mcp_connection(selected):await()
      end),
      reload = true,
    },
  }

  local default_callback = function(selected)
    if not selected then
      if callback then
        callback(nil)
      end
      return
    end

    Promise.async(function()
      toggle_mcp_connection(selected):await()
      if callback then
        callback(selected)
      end
    end)()
  end

  return base_picker.pick({
    items = initial_items,
    format_fn = format_mcp_item,
    actions = actions,
    callback = default_callback,
    title = 'MCP Servers',
    width = 65,
  })
end

return M
