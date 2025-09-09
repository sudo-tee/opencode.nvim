---@generic T
---@class Promise<T>
---@field and_then fun(self: self, callback: fun(value: any)): self
---@field resolve fun(self: self, value: any): self
---@field reject fun(self: self, err: any): self
---@field catch fun(self: self, callback: fun(err: any)): self
---@field wait fun(self: self, timeout?: integer, interval?: integer): any
---@field is_resolved fun(self: self): boolean
---@field is_rejected fun(self: self): boolean
---@field _resolved boolean
---@field _value any
---@field _error any
---@field _then_callbacks fun(value: any)[]
---@field _catch_callbacks fun(err: any)[]
local Promise = {}
Promise.__index = Promise

---Create a waitable promise that can be resolved or rejected later
---@generic T
---@return Promise<T>
function Promise.new()
  local self = setmetatable({
    _resolved = false,
    _value = nil,
    _error = nil,
    _then_callbacks = {},
    _catch_callbacks = {},
  }, Promise)
  return self
end

---@generic T
---@param self Promise<T>
---@param value T
---@return Promise<T>
function Promise:resolve(value)
  if self._resolved then
    return self
  end
  self._value = value
  self._resolved = true

  local schedule_then = vim.schedule_wrap(function(cb, v)
    cb(v)
  end)
  for _, callback in ipairs(self._then_callbacks) do
    schedule_then(callback, value)
  end
  return self
end

---@generic T
---@param self Promise<T>
---@param error any
---@return self
function Promise:reject(error)
  if self._resolved then
    return self
  end
  self._error = error
  self._resolved = true

  local schedule_catch = vim.schedule_wrap(function(cb, err)
    cb(err)
  end)
  for _, callback in ipairs(self._catch_callbacks) do
    schedule_catch(callback, error)
  end
  return self
end

---@generic T
---@param self self
---@param callback fun(value: T)
---@return self
function Promise:and_then(callback)
  if not callback then
    error('callback is required')
  end
  if self._resolved and not self._error then
    local schedule_then = vim.schedule_wrap(function(cb, v)
      cb(v)
    end)
    schedule_then(callback, self._value)
  else
    table.insert(self._then_callbacks, callback)
  end
  return self
end

---@generic T
---@param self self
---@param error_callback fun(err: any)
---@return self
function Promise:catch(error_callback)
  if self._resolved and self._error then
    local schedule_catch = vim.schedule_wrap(function(cb, err)
      cb(err)
    end)
    schedule_catch(error_callback, self._error)
  else
    table.insert(self._catch_callbacks, error_callback)
  end
  return self
end

---@generic T
---@param self self
---@param timeout integer|nil Timeout in milliseconds (default: 5000)
---@param interval integer|nil Interval in milliseconds to check (default: 100)
---@return T
function Promise:wait(timeout, interval)
  if self._resolved then
    if self._error then
      error(self._error)
    end
    return self._value
  end

  timeout = timeout or 5000
  interval = interval or 100

  local success = vim.wait(timeout, function()
    return self._resolved
  end, interval)

  if not success then
    error('Promise timed out after ' .. timeout .. 'ms')
  end

  if self._error then
    error(self._error)
  end

  return self._value
end

function Promise:is_resolved()
  return self._resolved
end

function Promise:is_rejected()
  return self._resolved and self._error ~= nil
end

return Promise
