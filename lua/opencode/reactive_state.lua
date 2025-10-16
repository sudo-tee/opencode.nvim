local M = {}

local function shallow_copy(obj)
  if type(obj) ~= 'table' then
    return obj
  end

  local copy = {}
  for key, value in pairs(obj) do
    copy[key] = value
  end
  return copy
end

local function merge_array(t1, t2)
  local result = shallow_copy(t1 or {})
  return vim.list_extend(result, t2 or {})
end

local function update_path(obj, path_parts, value)
  if #path_parts == 0 then
    return value
  end

  local key = path_parts[1]
  local rest = vim.list_slice(path_parts, 2)

  local new_obj = shallow_copy(obj)

  new_obj[key] = update_path(new_obj[key] or {}, rest, value)

  return new_obj
end

---@generic T
--- Create a new reactive state manager
---@param initial_state T Initial state
---@return table state manager with set, watch, and get methods
function M.create(initial_state)
  initial_state = initial_state or {}

  local _state = shallow_copy(initial_state)

  ---@type table<string, fun(path:string, new_val:any, old_val:any)[]>
  local _listeners = {}

  local function split_path(path)
    return type(path) == 'string' and vim.split(path, '.', { plain = true }) or path
  end

  local function get_by_path(obj, path)
    path = split_path(path)

    local current = obj
    for _, key in ipairs(path) do
      if type(current) ~= 'table' then
        return nil
      end
      current = current[key]
    end
    return current
  end

  local function notify(path, new_val, old_val)
    local listeners = merge_array(_listeners[path], _listeners['*'])
    for _, cb in ipairs(listeners) do
      pcall(cb, path, new_val, old_val)
    end
  end

  local state_manager = {}

  --- Set state value at path or using producer function
  ---@generic T
  ---@param path_or_producer string|fun(draft:T):T|nil Path to set or producer function
  ---@param value any
  function state_manager.set(path_or_producer, value)
    if type(path_or_producer) == 'function' then
      local producer = path_or_producer
      local draft = shallow_copy(_state)

      local result = producer(draft)
      local new_state = result or draft

      local old_state = _state
      _state = shallow_copy(new_state)

      local all_keys = merge_array(vim.tbl_keys(old_state), vim.tbl_keys(_state))

      for _, k in ipairs(all_keys) do
        local old_val = old_state[k]
        local new_val = _state[k]
        if old_val ~= new_val then
          notify(k, new_val, old_val)
        end
      end
    else
      local path = path_or_producer
      local path_parts = split_path(path)
      local old_val = get_by_path(_state, path_parts)

      if old_val ~= value then
        _state = update_path(_state, path_parts, value)
        notify(path, value, old_val)
      end
    end
  end

  --- Watch for changes to a specific path or all changes
  ---@param path string|nil Path to watch, or nil/'*' for all changes
  ---@param callback fun(path:string, new_val:any, old_val:any)
  ---@return fun() unsubscribe function
  function state_manager.watch(path, callback)
    path = path or '*'

    _listeners[path] = _listeners[path] or {}
    table.insert(_listeners[path], callback)

    local unsub = function()
      _listeners[path] = vim.tbl_filter(function(cb)
        return cb ~= callback
      end, _listeners[path] or {})
    end
    return unsub
  end

  --- Get current state or value at path
  ---@param path string|nil Path to get, or nil for entire state
  ---@return any
  function state_manager.get(path)
    if path == nil or path == '' then
      return shallow_copy(_state)
    end
    return get_by_path(_state, path)
  end

  return state_manager
end

return M
