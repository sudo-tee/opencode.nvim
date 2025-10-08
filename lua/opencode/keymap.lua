local M = {}

-- Binds a keymap config with its api fn
-- Name of api fn & keymap global config should always be the same
---@param keymap OpencodeKeymap The keymap configuration table
function M.setup(keymap)
  local api = require('opencode.api')
  local cmds = api.commands
  local global = keymap.global

  -- keymap.setup() expects the new format - config normalization should happen in config.setup()

  -- Handle keymap configuration (normalized to new format)
  for key_binding, config_entry in pairs(global) do
    local func_name
    local modes = { 'n', 'v' } -- Default modes

    if type(config_entry) == 'string' then
      -- Simple format: key = 'function_name'
      func_name = config_entry
    elseif type(config_entry) == 'table' then
      -- Table format: key = { 'function_name', mode = ... }
      func_name = config_entry[1]
      if config_entry.mode then
        -- Modes are explicitly specified, use them as-is
        if type(config_entry.mode) == 'string' then
          modes = { config_entry.mode }
        elseif type(config_entry.mode) == 'table' then
          modes = config_entry.mode
        end
      end
    end

    if func_name and api[func_name] then
      vim.keymap.set(modes, key_binding, function()
        api[func_name]()
      end, { silent = false, desc = cmds[func_name] and cmds[func_name].desc })
    end
  end
end

---@param lhs string|false The left-hand side of the mapping, `false` disables keymaps
---@param rhs function|string The right-hand side of the mapping
---@param bufnrs number|number[] Buffer number(s) to set the mapping for
---@param mode string|string[] Agent(s) for the mapping
---@param opts? table Additional options for vim.keymap.set
function M.buf_keymap(lhs, rhs, bufnrs, mode, opts)
  if not lhs then
    return
  end

  opts = opts or { silent = true }
  bufnrs = type(bufnrs) == 'table' and bufnrs or { bufnrs }

  for _, bufnr in ipairs(bufnrs) do
    if
      not vim.api.nvim_buf_is_valid(bufnr --[[@as number]])
    then
      vim.notify(string.format('Invalid buffer number: %s', bufnr), vim.log.levels.WARN)
      return
    end
    vim.keymap.set(mode, lhs, rhs, vim.tbl_extend('force', opts, { buffer = bufnr }))
  end
end

function M.clear_permission_keymap(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local config = require('opencode.config')

  pcall(function()
    local permission_config = config.get().keymap.permission
    if not permission_config then
      return
    end

    for _, key in pairs(permission_config) do
      if key then
        vim.api.nvim_buf_del_keymap(buf, 'n', key)
        vim.api.nvim_buf_del_keymap(buf, 'i', key)
      end
    end
  end)
end

function M.toggle_permission_keymap(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local state = require('opencode.state')
  local config = require('opencode.config')
  local api = require('opencode.api')

  if state.current_permission then
    local permission_config = config.get().keymap.permission
    if not permission_config then
      return
    end

    for action, key in pairs(permission_config) do
      local api_func = api['permission_' .. action]
      if key and api_func then
        M.buf_keymap(key, api_func, buf, { 'n', 'i' })
      end
    end
  else
    M.clear_permission_keymap(buf)
  end
end

return M
