---@class OpencodeProtectedStateSetOptions
---@field source? 'helper'|'raw'
---@field silent? boolean

local M = {}

local _state = {
  windows = nil,
  is_opening = false,
  input_content = {},
  is_opencode_focused = false,
  last_focused_opencode_window = nil,
  last_input_window_position = nil,
  last_output_window_position = nil,
  last_code_win_before_opencode = nil,
  current_code_buf = nil,
  saved_window_options = nil,
  display_route = nil,
  current_mode = nil,
  last_output = 0,
  pre_zoom_width = nil,
  last_window_width_ratio = nil,
  last_sent_context = nil,
  current_context_config = {},
  context_updated_at = nil,
  active_session = nil,
  restore_points = {},
  current_model = nil,
  user_mode_model_map = {},
  current_model_info = nil,
  current_variant = nil,
  messages = nil,
  current_message = nil,
  last_user_message = nil,
  pending_permissions = {},
  cost = 0,
  tokens_count = 0,
  job_count = 0,
  user_message_count = {},
  opencode_server = nil,
  api_client = nil,
  event_manager = nil,
  required_version = '0.6.3',
  opencode_cli_version = nil,
  current_cwd = vim.fn.getcwd(),
  _hidden_buffers = nil,
}

local _listeners = {}

local PROTECTED_KEYS = {
  active_session = true,
  restore_points = true,
  job_count = true,
  opencode_server = true,
  windows = true,
  is_opening = true,
  is_opencode_focused = true,
  last_focused_opencode_window = true,
  last_code_win_before_opencode = true,
  current_code_buf = true,
  display_route = true,
  last_window_width_ratio = true,
  current_mode = true,
  current_model = true,
  current_model_info = true,
  current_variant = true,
  user_mode_model_map = true,
}

local _protected_write_warnings = {}
local _silence_protected_writes = false

---@param key string
---@param opts? OpencodeProtectedStateSetOptions
local function warn_on_protected_raw_write(key, opts)
  if not PROTECTED_KEYS[key] or _protected_write_warnings[key] then
    return
  end

  if _silence_protected_writes or (opts and opts.silent) then
    return
  end

  _protected_write_warnings[key] = true
  vim.schedule(function()
    vim.notify(
      string.format('Direct write to protected state key `%s`; prefer state domain helpers', key),
      vim.log.levels.WARN
    )
  end)
end

function M.state()
  return _state
end

---@param key string
---@return any
function M.get(key)
  return _state[key]
end

---@param key string
---@param value any
---@param opts? OpencodeProtectedStateSetOptions
---@return any
function M.set(key, value, opts)
  local old = _state[key]
  opts = opts or { source = 'helper' }

  if opts.source == 'raw' then
    warn_on_protected_raw_write(key, opts)
  end

  _state[key] = value
  if not vim.deep_equal(old, value) then
    M.notify(key, value, old)
  end

  return value
end

---@param key string
---@param value any
---@param opts? OpencodeProtectedStateSetOptions
---@return any
function M.set_raw(key, value, opts)
  local next_opts = vim.tbl_extend('force', { source = 'raw' }, opts or {})
  return M.set(key, value, next_opts)
end

---@generic T
---@param key string
---@param updater fun(current: T): T
---@param opts? OpencodeProtectedStateSetOptions
---@return T
function M.update(key, updater, opts)
  local next_value = updater(_state[key])
  M.set(key, next_value, opts)
  return next_value
end

---@param key string|string[]|nil
---@param cb fun(key:string, new_val:any, old_val:any)
function M.subscribe(key, cb)
  if type(key) == 'table' then
    for _, current_key in ipairs(key) do
      M.subscribe(current_key, cb)
    end
    return
  end

  key = key or '*'
  if not _listeners[key] then
    _listeners[key] = {}
  end

  for _, fn in ipairs(_listeners[key]) do
    if fn == cb then
      return
    end
  end

  table.insert(_listeners[key], cb)
end

---@param key string|nil
---@param cb fun(key:string, new_val:any, old_val:any)
function M.unsubscribe(key, cb)
  key = key or '*'
  local list = _listeners[key]
  if not list then
    return
  end

  for i = #list, 1, -1 do
    if list[i] == cb then
      table.remove(list, i)
    end
  end
end

function M.notify(key, new_val, old_val)
  vim.schedule(function()
    if _listeners[key] then
      for _, cb in ipairs(_listeners[key]) do
        local ok, err = pcall(cb, key, new_val, old_val)
        if not ok then
          vim.notify(err --[[@as string]])
        end
      end
    end

    if _listeners['*'] then
      for _, cb in ipairs(_listeners['*']) do
        pcall(cb, key, new_val, old_val)
      end
    end
  end)
end

---@param key string
---@param value any
function M.append(key, value)
  if type(value) ~= 'table' then
    error('Value must be a table to append')
  end
  if not _state[key] then
    _state[key] = {}
  end
  if type(_state[key]) ~= 'table' then
    error('State key is not a table: ' .. key)
  end

  local old = vim.deepcopy(_state[key] --[[@as table]])
  table.insert(_state[key] --[[@as table]], value)
  M.notify(key, _state[key], old)
end

---@param key string
---@param idx integer
function M.remove(key, idx)
  if not _state[key] then
    return
  end
  if type(_state[key]) ~= 'table' then
    error('State key is not a table: ' .. key)
  end

  local old = vim.deepcopy(_state[key] --[[@as table]])
  table.remove(_state[key] --[[@as table]], idx)
  M.notify(key, _state[key], old)
end

---@param enabled boolean
function M.set_protected_writes_silenced(enabled)
  _silence_protected_writes = enabled == true
end

---@return boolean
function M.are_protected_writes_silenced()
  return _silence_protected_writes
end

function M.reset_protected_write_warnings()
  _protected_write_warnings = {}
end

---@param key string
---@return boolean
function M.is_protected_key(key)
  return PROTECTED_KEYS[key] == true
end

return M
