local M = {}

-- Helper function to process keymap entries
---@param keymap_config table The keymap configuration table
---@param default_modes table Default modes for these keymaps
---@param base_opts table Base options to use for all keymaps
local function process_keymap_entry(keymap_config, default_modes, base_opts)
  local api = require('opencode.api')
  local cmds = api.commands

  for key_binding, config_entry in pairs(keymap_config) do
    if config_entry == false then
      -- Skip keymap if explicitly set to false (disabled)
    elseif config_entry then
      local func_name = config_entry[1]
      local callback = type(func_name) == 'function' and func_name or api[func_name]
      local modes = config_entry.mode or default_modes
      local opts = vim.tbl_deep_extend('force', {}, base_opts)
      opts.desc = config_entry.desc or cmds[func_name] and cmds[func_name].desc

      if callback then
        vim.keymap.set(modes, key_binding, callback, opts)
      else
        vim.notify(string.format('No action found for keymap: %s -> %s', key_binding, func_name), vim.log.levels.WARN)
      end
    end
  end
end

-- Binds a keymap config with its api fn
-- Name of api fn & keymap editor config should always be the same
---@param keymap OpencodeKeymap The keymap configuration table
function M.setup(keymap)
  process_keymap_entry(keymap.editor or {}, { 'n', 'v' }, { silent = false })
end

-- Setup window-specific keymaps (shared helper for input/output windows)
---@param keymap_config table Window keymap configuration
---@param buf_id integer Buffer ID to set keymaps for
function M.setup_window_keymaps(keymap_config, buf_id)
  if not vim.api.nvim_buf_is_valid(buf_id) then
    return
  end

  process_keymap_entry(keymap_config or {}, { 'n' }, { silent = true, buffer = buf_id })
end

---Add permission keymaps if permissions are being requested,
---otherwise remove them
---@param buf any
function M.toggle_permission_keymap(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local state = require('opencode.state')
  local config = require('opencode.config')
  local api = require('opencode.api')

  local permission_config = config.keymap.permission
  if not permission_config then
    return
  end

  -- Check for permissions from permission window first, fallback to state
  local permission_window = require('opencode.ui.permission_window')
  local has_permissions = permission_window.get_permission_count() > 0

  if has_permissions then
    for action, key in pairs(permission_config) do
      local api_func = api['permission_' .. action]
      if key and api_func then
        vim.keymap.set({ 'n', 'i' }, key, api_func, { buffer = buf, silent = true })
      end
    end
    return
  end

  -- not requesting permissions, clear keymaps
  for _, key in pairs(permission_config) do
    if key then
      pcall(vim.api.nvim_buf_del_keymap, buf, 'n', key)
      pcall(vim.api.nvim_buf_del_keymap, buf, 'i', key)
    end
  end
end

return M
