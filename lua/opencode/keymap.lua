local M = {}

local function is_completion_visible()
  local ok, completion = pcall(require, 'opencode.ui.completion')
  return ok and completion.is_visible()
end

local function wrap_with_completion_check(key_binding, callback)
  return function()
    if is_completion_visible() then
      return vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key_binding, true, false, true), 'n', false)
    end
    return callback()
  end
end

---@param keymap_config table The keymap configuration table
---@param default_modes table Default modes for these keymaps
---@param base_opts table Base options to use for all keymaps
---@param defer_to_completion boolean? Whether to defer to completion engine when visible
local function process_keymap_entry(keymap_config, default_modes, base_opts, defer_to_completion)
  local api = require('opencode.api')
  local cmds = api.commands

  for key_binding, config_entry in pairs(keymap_config) do
    if config_entry == false then
      -- Skip keymap if explicitly set to false (disabled)
    elseif config_entry then
      local func_name = config_entry[1]
      local func_args = config_entry[2]
      local raw_callback = type(func_name) == 'function' and func_name or api[func_name]
      local callback = raw_callback

      if raw_callback and func_args then
        callback = function()
          raw_callback(func_args)
        end
      end

      local modes = config_entry.mode or default_modes
      local opts = vim.tbl_deep_extend('force', {}, base_opts)
      opts.desc = config_entry.desc or cmds[func_name] and cmds[func_name].desc

      if callback then
        if defer_to_completion then
          callback = wrap_with_completion_check(key_binding, callback)
        end
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

---@param keymap_config table Window keymap configuration
---@param buf_id integer Buffer ID to set keymaps for
---@param defer_to_completion boolean? Whether to defer to completion engine when visible (default: false)
function M.setup_window_keymaps(keymap_config, buf_id, defer_to_completion)
  if not vim.api.nvim_buf_is_valid(buf_id) then
    return
  end

  process_keymap_entry(keymap_config or {}, { 'n' }, { silent = true, buffer = buf_id }, defer_to_completion)
end

return M
