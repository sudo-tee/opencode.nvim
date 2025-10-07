local api = require('opencode.api')

local M = {}

-- Default modes for window keymaps based on current hardcoded behavior
local function get_default_window_modes(keymap_name)
  local defaults = {
    submit = 'n',
    submit_insert = 'i',
    mention = 'i',
    slash_commands = 'i',
    mention_file = 'i',
    prev_prompt_history = { 'n', 'i' },
    next_prompt_history = { 'n', 'i' },
    switch_mode = { 'n', 'i' },
    next_message = 'n',
    prev_message = 'n',
    close = 'n',
    stop = 'n',
    toggle_pane = { 'n', 'i' },
    focus_input = 'n',
    select_child_session = 'n',
    debug_message = 'n',
    debug_output = 'n',
    debug_session = 'n',
  }
  return defaults[keymap_name] or 'n'
end

-- Default modes for global keymaps based on current hardcoded behavior
local function get_default_global_modes(keymap_name)
  -- All global keymaps currently use { 'n', 'v' } modes
  return { 'n', 'v' }
end

-- Parse keymap value (string or table) and return key and mode
---@param keymap_value string | { key: string, mode: string|string[] } | { [1]: string, [2]: string|string[] }
---@param keymap_name string
---@param default_modes_fn function
---@return string key, string|string[] mode
local function parse_keymap_value(keymap_value, keymap_name, default_modes_fn)
  if type(keymap_value) == 'string' then
    return keymap_value, default_modes_fn(keymap_name)
  elseif type(keymap_value) == 'table' then
    -- Support positional format: { '<key>', 'mode' }
    if keymap_value[1] then
      local key = keymap_value[1]
      local mode = keymap_value[2] or default_modes_fn(keymap_name)
      return key, mode
    -- Support named format: { key = '<key>', mode = 'mode' }
    elseif keymap_value.key then
      return keymap_value.key, keymap_value.mode or default_modes_fn(keymap_name)
    end
  end
  error('Invalid keymap value for ' .. keymap_name .. ': ' .. vim.inspect(keymap_value))
end

-- Parse a window keymap value using window-specific defaults
---@param keymap_value OpencodeKeymapWindowValue
---@param keymap_name string
---@return string key, string|string[] mode
function M.parse_window_keymap(keymap_value, keymap_name)
  return parse_keymap_value(keymap_value, keymap_name, get_default_window_modes)
end

-- Parse a global keymap value using global-specific defaults
---@param keymap_value OpencodeKeymapGlobalValue
---@param keymap_name string
---@return string key, string|string[] mode
function M.parse_global_keymap(keymap_value, keymap_name)
  return parse_keymap_value(keymap_value, keymap_name, get_default_global_modes)
end

-- Binds a keymap config with its api fn
-- Name of api fn & keymap global config should always be the same
---@param keymap OpencodeKeymap The keymap configuration table
function M.setup(keymap)
  local cmds = api.commands
  local global = keymap.global

  -- Process global keymaps using the new parsing approach
  for keymap_name, keymap_value in pairs(global) do
    if keymap_value then
      local key, mode = M.parse_global_keymap(keymap_value, keymap_name)
      vim.keymap.set(mode, key, function()
        api[keymap_name]()
      end, { silent = false, desc = cmds[keymap_name] and cmds[keymap_name].desc })
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

return M
