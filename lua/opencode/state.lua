local config = require('opencode.config').get()

---@class OpencodeWindowState
---@field input_win number|nil
---@field output_win number|nil
---@field footer_win number|nil
---@field footer_buf number|nil
---@field input_buf number|nil
---@field output_buf number|nil

---@class OpencodeState
---@field windows OpencodeWindowState|nil
---@field input_content table
---@field last_focused_opencode_window string|nil
---@field last_input_window_position number|nil
---@field last_output_window_position number|nil
---@field last_code_win_before_opencode number|nil
---@field display_route any|nil
---@field current_mode string
---@field last_output number
---@field last_sent_context any
---@field active_session Session|nil
---@field new_session_name string|nil
---@field restore_points table<string, any>
---@field current_model string|nil
---@field messages Message[]|nil
---@field current_message Message|nil
---@field last_user_message Message|nil
---@field cost number
---@field tokens_count number
---@field is_job_running boolean
---@field opencode_server_job OpencodeServer|nil
---@field api_client OpencodeApiClient
---@field subscribe fun( key:string|nil, cb:fun(key:string, new_val:any, old_val:any))
---@field unsubscribe fun( key:string|nil, cb:fun(key:string, new_val:any, old_val:any))
---@field is_running fun():boolean
---@field append fun( key:string, value:any)
---@field required_version string
---@field opencode_cli_version string|nil

-- Internal raw state table
local _state = {
  -- ui
  windows = nil, ---@type OpencodeWindowState
  input_content = {},
  last_focused_opencode_window = nil,
  last_input_window_position = nil,
  last_output_window_position = nil,
  last_code_win_before_opencode = nil,
  display_route = nil,
  current_mode = config.default_mode,
  last_output = 0,
  -- context
  last_sent_context = nil,
  -- session
  active_session = nil,
  new_session_name = nil,
  restore_points = {},
  current_model = nil,
  -- messages
  messages = nil,
  current_message = nil,
  last_user_message = nil,
  cost = 0,
  tokens_count = 0,
  -- job
  is_job_running = false,
  opencode_server_job = nil,
  api_client = nil,

  -- versions
  required_version = '0.6.3',
  opencode_cli_version = nil,
}

-- Listener registry: { [key] = {cb1, cb2, ...}, ['*'] = {cb1, ...} }
local _listeners = {}

--- Subscribe to changes for a key (or all keys with '*').
---@param key string|nil If nil or '*', listens to all keys
---@param cb fun(key:string, new_val:any, old_val:any)
---@usage
---   state.subscribe('foo', function(key, new, old) ... end)
---   state.subscribe('*', function(key, new, old) ... end)
local function subscribe(key, cb)
  key = key or '*'
  if not _listeners[key] then
    _listeners[key] = {}
  end
  table.insert(_listeners[key], cb)
end

--- Unsubscribe a callback for a key (or all keys)
---@param key string|nil
---@param cb fun(key:string, new_val:any, old_val:any)
local function unsubscribe(key, cb)
  key = key or '*'
  local list = _listeners[key]
  if not list then
    return
  end
  for i, fn in ipairs(list) do
    if fn == cb then
      table.remove(list, i)
      break
    end
  end
end

-- Notify listeners
local function _notify(key, new_val, old_val)
  if _listeners[key] then
    for _, cb in ipairs(_listeners[key]) do
      pcall(cb, key, new_val, old_val)
    end
  end
  if _listeners['*'] then
    for _, cb in ipairs(_listeners['*']) do
      pcall(cb, key, new_val, old_val)
    end
  end
end

local function append(key, value)
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
  _notify(key, _state[key], old)
end

--- Observable state proxy. All reads/writes go through this table.
--- Use `state.subscribe(key, cb)` to listen for changes.
--- Use `state.unsubscribe(key, cb)` to remove listeners.
---
--- Example:
---   state.subscribe('foo', function(key, new, old) print(key, new, old) end)
---   state.foo = 42 -- triggers callback
---@type OpencodeState
local M = {}
setmetatable(M, {
  __index = function(_, k)
    return _state[k]
  end,
  __newindex = function(_, k, v)
    local old = _state[k]
    _state[k] = v
    if not vim.deep_equal(old, v) then
      _notify(k, v, old)
    end
  end,
  __pairs = function()
    return pairs(_state)
  end,
  __ipairs = function()
    return ipairs(_state)
  end,
})

M.append = append
M.subscribe = subscribe
M.unsubscribe = unsubscribe

---
--- Returns true if any job (run or server) is running
---
function M.is_running()
  return M.is_job_running
end

return M
