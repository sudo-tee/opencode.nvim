local M = {}

---@type fun(name: string, args: any): function?, string?
M.resolve_command = function(name, _args)
  vim.notify(
    'Keymap command routing not initialized; cannot resolve action: ' .. name .. ' (require opencode.keymap first)',
    vim.log.levels.ERROR
  )
end

local function normalize_lhs(lhs)
  return vim.api.nvim_replace_termcodes(lhs, true, true, true)
end

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
---@param actions? table<string, function?> Buffer-local overrides take precedence over panel commands
---@return function|nil, string?
local function resolve_callback(func_name, func_args, actions)
  if type(func_name) == 'string' and actions and actions[func_name] then
    func_name = actions[func_name]
  end
  if type(func_name) == 'function' then
    return function()
      local args = func_args and (type(func_args) == 'table' and vim.deepcopy(func_args) or { func_args }) or {}
      return func_name(unpack(args))
    end
  end

  if type(func_name) == 'string' then
    return M.resolve_command(func_name, func_args)
  end

  return nil
end

---@param keymap_config table The keymap configuration table
---@param default_modes table Default modes for these keymaps
---@param base_opts table Base options to use for all keymaps
---@param preserve_existing? boolean
---@param actions? table<string, function?>
function M.setup_keymaps(keymap_config, default_modes, base_opts, preserve_existing, actions)
  for key_binding, config_entry in pairs(keymap_config) do
    if config_entry == false then
      -- Skip keymap if explicitly set to false (disabled)
    elseif config_entry then
      local func_name = config_entry[1]
      local func_args = config_entry[2]
      local callback, command_desc = resolve_callback(func_name, func_args, actions)

      local modes = config_entry.mode or default_modes
      if preserve_existing and base_opts.buffer then
        local missing_modes = {}
        for _, mode in ipairs(type(modes) == 'table' and modes or { modes }) do
          local exists = false
          for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(base_opts.buffer, mode)) do
            if normalize_lhs(mapping.lhs) == normalize_lhs(key_binding) then
              exists = true
              break
            end
          end
          if not exists then
            table.insert(missing_modes, mode)
          end
        end
        modes = missing_modes
      end
      local opts = vim.tbl_deep_extend('force', {}, base_opts)
      opts.nowait = config_entry.nowait
      opts.desc = config_entry.desc or command_desc or ''

      if not callback then
        if type(func_name) ~= 'string' then
          vim.notify(string.format('No action found for keymap: %s -> %s', key_binding, func_name), vim.log.levels.WARN)
        end
      elseif #modes > 0 then
        if config_entry.defer_to_completion then
          callback = wrap_with_completion_check(key_binding, callback)
        end
        vim.keymap.set(modes, key_binding, callback, opts)
      end
    end
  end
end

---@param keymap_config table Window keymap configuration
---@param buf_id integer Buffer ID to set keymaps for
---@param preserve_existing? boolean
---@param actions? table<string, function?> Local action overrides; unknown names use command resolution and its error notification
function M.setup_window_keymaps(keymap_config, buf_id, preserve_existing, actions)
  if not vim.api.nvim_buf_is_valid(buf_id) then
    return
  end

  M.setup_keymaps(keymap_config or {}, { 'n' }, { silent = true, buffer = buf_id }, preserve_existing, actions)
end

return M
