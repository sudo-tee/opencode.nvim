local M = {}
local store = require('opencode.state.store')
local window_keymaps = {}

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
---@return function|nil
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
    local commands = require('opencode.commands')
    local command_defs = commands.get_commands()
    if command_defs[func_name] then
      return function()
        local args = func_args and (type(func_args) == 'table' and vim.deepcopy(func_args) or { func_args }) or {}
        local parsed = commands.build_parsed_intent(func_name, args)
        return commands.execute_parsed_intent(parsed)
      end
    end

    vim.notify('Cannot find keymap action: ' .. func_name, vim.log.levels.ERROR)
    return nil
  end

  return nil
end

---@param keymap_config table The keymap configuration table
---@param default_modes table Default modes for these keymaps
---@param base_opts table Base options to use for all keymaps
---@param preserve_existing? boolean
---@param actions? table<string, function?>
local function process_keymap_entry(keymap_config, default_modes, base_opts, preserve_existing, actions)
  -- Commands load diff handlers, which also use this mapper for their buffers.
  local commands = require('opencode.commands')
  local command_defs = commands.get_commands()

  for key_binding, config_entry in pairs(keymap_config) do
    if config_entry == false then
      -- Skip keymap if explicitly set to false (disabled)
    elseif config_entry then
      local func_name = config_entry[1]
      local func_args = config_entry[2]
      local callback = resolve_callback(func_name, func_args, actions)

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
      local command_desc = type(func_name) == 'string'
        and not (actions and actions[func_name])
        and vim.tbl_get(command_defs, func_name, 'desc')
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

local function setup_panel_keymaps(_, windows, previous)
  if not windows then
    return
  end
  for _, name in ipairs({ 'input', 'output', 'tab_strip' }) do
    local buf, win = windows[name .. '_buf'], windows[name .. '_win']
    local changed = not previous or previous[name .. '_buf'] ~= buf or previous[name .. '_win'] ~= win
    if
      changed
      and buf
      and vim.api.nvim_buf_is_valid(buf)
      and (name == 'tab_strip' or win and vim.api.nvim_win_is_valid(win))
    then
      M.setup_window_keymaps(window_keymaps[name .. '_window'], buf, true)
    end
  end
end

---@param keymap OpencodeKeymap The keymap configuration table
function M.setup(keymap)
  process_keymap_entry(keymap.editor or {}, { 'n', 'v' }, { silent = false })
  window_keymaps = keymap
  store.subscribe('windows', setup_panel_keymaps)
  setup_panel_keymaps(nil, store.get('windows'))
end

function M.teardown()
  store.unsubscribe('windows', setup_panel_keymaps)
  window_keymaps = {}
end

---@param keymap_config table Window keymap configuration
---@param buf_id integer Buffer ID to set keymaps for
---@param preserve_existing? boolean
---@param actions? table<string, function?> Local action overrides; unknown names use command resolution and its error notification
function M.setup_window_keymaps(keymap_config, buf_id, preserve_existing, actions)
  if not vim.api.nvim_buf_is_valid(buf_id) then
    return
  end

  process_keymap_entry(keymap_config or {}, { 'n' }, { silent = true, buffer = buf_id }, preserve_existing, actions)
end

return M
