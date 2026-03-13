---@class OpencodeProtectedStateSetOptions
---@field source? 'helper'|'raw'
---@field silent? boolean

---@alias StateValue<K> K extends keyof OpencodeState and StateValue<K> or never

local M = {}

---@type OpencodeState
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

---@param key string
---@param opts? OpencodeProtectedStateSetOptions
local function error_on_raw_write(key, opts)
  if opts and opts.silent then
    return
  end

  error(string.format('Direct write to state key `%s` is not allowed; use a state domain setter', key), 3)
end

function M.state()
  return _state
end

---@generic K extends keyof OpencodeState
---@param key K
---@return OpencodeState[K]
function M.get(key)
  return _state[key]
end

local c = M.get('user_message_counte')

---@generic K extends keyof OpencodeState
---@param key K
---@param value StateValue<K>
---@param opts? OpencodeProtectedStateSetOptions
---@return StateValue<K>
function M.set(key, value, opts)
  local old = _state[key]
  opts = opts or { source = 'helper' }

  if opts.source == 'raw' then
    error_on_raw_write(key, opts)
  end

  _state[key] = value
  if not vim.deep_equal(old, value) then
    M.emit(key, value, old)
  end

  return value
end

---@generic K extends keyof OpencodeState
---@param key K
---@param value StateValue<K>
---@param opts? OpencodeProtectedStateSetOptions
---@return StateValue<K>
function M.set_raw(key, value, opts)
  local next_opts = vim.tbl_extend('force', { source = 'raw' }, opts or {})
  return M.set(key, value, next_opts)
end

---@generic K extends keyof OpencodeState
---@param key K
---@param updater fun(current: StateValue<K>): StateValue<K>
---@param opts? OpencodeProtectedStateSetOptions
---@return StateValue<K>
function M.update(key, updater, opts)
  local next_value = updater(_state[key])
  M.set(key, next_value, opts)
  return next_value
end

---@generic K extends keyof OpencodeState
---@param key K|K[]|nil
---@param cb fun(key:K, new_val:StateValue<K>, old_val:StateValue<K>)
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

---@generic K extends keyof OpencodeState
---@param key K|nil
---@param cb fun(key:K, new_val:StateValue<K>, old_val:StateValue<K>)
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

---@generic K extends keyof OpencodeState
---@param key K
---@param new_val StateValue<K>
---@param old_val StateValue<K>
function M.emit(key, new_val, old_val)
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

---@generic K extends keyof OpencodeState
---@param key K
---@param value StateValue<K> extends any[] and StateValue<K>[integer] or never
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
  M.emit(key, _state[key], old)
end

---@generic K extends keyof OpencodeState
---@param key K
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
  M.emit(key, _state[key], old)
end

return M
