local M = {}
local commands = require('opencode.commands')

local function is_completion_visible()
  return require('opencode.ui.completion').is_completion_visible()
end

---@param key_binding string The key binding to feed if completion is visible
---@param callback function The callback to execute if completion is not visible
local function wrap_with_completion_check(key_binding, callback)
  return function()
    if is_completion_visible() then
      return vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key_binding, true, false, true), 'n', false)
    end
    return callback()
  end
end

---@param func_name string|function
---@param func_args any
---@return function|nil
local function resolve_callback(func_name, func_args)
  if type(func_name) == 'function' then
    return func_name
  end

  if type(func_name) == 'string' then
    local command_defs = commands.get_commands()
    if command_defs[func_name] then
      return function()
        local args = func_args and (type(func_args) == 'table' and func_args or { func_args }) or {}
        commands.execute_command_opts({ args = table.concat(vim.list_extend({ func_name }, args), ' '), range = 0 })
      end
    end

    vim.notify('Unroutable string keymap action: ' .. func_name, vim.log.levels.ERROR)
    return nil
  end

  return nil
end

---@param keymap_config table The keymap configuration table
---@param default_modes table Default modes for these keymaps
---@param base_opts table Base options to use for all keymaps
local function process_keymap_entry(keymap_config, default_modes, base_opts)
  local command_defs = commands.get_commands()

  for key_binding, config_entry in pairs(keymap_config) do
    if config_entry == false then
      -- Skip keymap if explicitly set to false (disabled)
    elseif config_entry then
      local func_name = config_entry[1]
      local func_args = config_entry[2]
      local callback = resolve_callback(func_name, func_args)

      local modes = config_entry.mode or default_modes
      local opts = vim.tbl_deep_extend('force', {}, base_opts)
      opts.desc = config_entry.desc
        or type(func_name) == 'string' and command_defs[func_name] and command_defs[func_name].desc

      if callback then
        if config_entry.defer_to_completion then
          callback = wrap_with_completion_check(key_binding, callback)
        end
        vim.keymap.set(modes, key_binding, callback, opts)
      elseif type(func_name) ~= 'string' then
        vim.notify(string.format('No action found for keymap: %s -> %s', key_binding, func_name), vim.log.levels.WARN)
      end
    end
  end
end

---@param keymap OpencodeKeymap The keymap configuration table
function M.setup(keymap)
  process_keymap_entry(keymap.editor or {}, { 'n', 'v' }, { silent = false })
end

---@param keymap_config table Window keymap configuration
---@param buf_id integer Buffer ID to set keymaps for
function M.setup_window_keymaps(keymap_config, buf_id)
  if not vim.api.nvim_buf_is_valid(buf_id) then
    return
  end

  process_keymap_entry(keymap_config or {}, { 'n' }, { silent = true, buffer = buf_id })
end

return M
