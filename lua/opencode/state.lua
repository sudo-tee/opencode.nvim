local config = require('opencode.config')

---@class OpencodeWindowState
---@field input_win integer|nil
---@field output_win integer|nil
---@field footer_win integer|nil
---@field footer_buf integer|nil
---@field input_buf integer|nil
---@field output_buf integer|nil

---@class OpencodeState
---@field windows OpencodeWindowState|nil
---@field input_content table
---@field is_opencode_focused boolean
---@field last_focused_opencode_window string|nil
---@field last_input_window_position number|nil
---@field last_output_window_position number|nil
---@field last_code_win_before_opencode number|nil
---@field current_code_buf number|nil
---@field display_route any|nil
---@field current_mode string
---@field last_output number
---@field last_sent_context OpencodeContext|nil
---@field current_context_config OpencodeContextConfig|nil
---@field context_updated_at number|nil
---@field active_session Session|nil
---@field restore_points RestorePoint[]
---@field current_model string|nil
---@field current_model_info table|nil
---@field messages OpencodeMessage[]|nil
---@field current_message OpencodeMessage|nil
---@field last_user_message OpencodeMessage|nil
---@field current_permission OpencodePermission|nil
---@field cost number
---@field tokens_count number
---@field job_count number
---@field opencode_server OpencodeServer|nil
---@field api_client OpencodeApiClient
---@field event_manager EventManager|nil
---@field required_version string
---@field opencode_cli_version string|nil
---@field append fun( key:string, value:any)
---@field remove fun( key:string, idx:number)
---@field subscribe fun( key:string|nil, cb:fun(key:string, new_val:any, old_val:any))
---@field opencode_server_job OpencodeServer
---@field subscribe fun( key:string|string[]|nil, cb:fun(key:string, new_val:any, old_val:any))
---@field unsubscribe fun( key:string|nil, cb:fun(key:string, new_val:any, old_val:any))
---@field is_running fun():boolean

-- Internal raw state table
local _state = {
  -- ui
  windows = nil, ---@type OpencodeWindowState|nil
  input_content = {},
  is_opencode_focused = false,
  last_focused_opencode_window = nil,
  last_input_window_position = nil,
  last_output_window_position = nil,
  last_code_win_before_opencode = nil,
  current_code_buf = nil,
  display_route = nil,
  current_mode = nil,
  last_output = 0,
  -- context
  last_sent_context = nil,
  current_context_config = {},
  context_updated_at = nil,
  -- session
  active_session = nil,
  restore_points = {},
  current_model = nil,
  current_model_info = nil,
  -- messages
  messages = nil,
  current_message = nil,
  last_user_message = nil,
  current_permission = nil,
  cost = 0,
  tokens_count = 0,
  -- job
  job_count = 0,
  opencode_server = nil,
  api_client = nil,
  event_manager = nil,

  -- versions
  required_version = '0.6.3',
  opencode_cli_version = nil,
}

-- Listener registry: { [key] = {cb1, cb2, ...}, ['*'] = {cb1, ...} }
local _listeners = {}

--- Subscribe to changes for a key (or all keys with '*').
---@param key string|string[]|nil If nil or '*', listens to all keys
---@param cb fun(key:string, new_val:any, old_val:any)
---@usage
---   state.subscribe('foo', function(key, new, old) ... end)
---   state.subscribe('*', function(key, new, old) ... end)
local function subscribe(key, cb)
  if type(key) == 'table' then
    for _, k in ipairs(key) do
      subscribe(k, cb)
    end
    return
  end
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
  -- schedule notification to make sure we're not in a fast event
  -- context
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

local function remove(key, idx)
  if not _state[key] then
    return
  end
  if type(_state[key]) ~= 'table' then
    error('State key is not a table: ' .. key)
  end

  local old = vim.deepcopy(_state[key] --[[@as table]])
  table.remove(_state[key] --[[@as table]], idx)
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
M.remove = remove
M.subscribe = subscribe
M.unsubscribe = unsubscribe

---
--- Returns true if any job (run or server) is running
---
function M.is_running()
  return M.job_count > 0
end

return M
