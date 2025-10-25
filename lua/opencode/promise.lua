---@generic T
---@class Promise<T>
---@field and_then fun(self: Promise<T>, callback: fun(value: T): any): Promise<any>
---@field resolve fun(self: self, value: any): self
---@field reject fun(self: self, err: any): self
---@field catch fun(self: Promise<T>, callback: fun(err: any): any): Promise<T>
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
function Promise:reject(err)
  if self._resolved then
    return self
  end
  self._error = err
  self._resolved = true

  local schedule_catch = vim.schedule_wrap(function(cb, e)
    cb(e)
  end)
  for _, callback in ipairs(self._catch_callbacks) do
    schedule_catch(callback, err)
  end
  return self
end

---@generic T, U
---@param self Promise<T>
---@param callback fun(value: T): U | Promise<U>
---@return Promise<U>
function Promise:and_then(callback)
  if not callback then
    error('callback is required')
  end

  local new_promise = Promise.new()

  local handle_callback = function(value)
    local ok, result = pcall(callback, value)
    if not ok then
      new_promise:reject(result)
      return
    end

    if type(result) == 'table' and result.and_then then
      result
        :and_then(function(val)
          new_promise:resolve(val)
        end)
        :catch(function(err)
          new_promise:reject(err)
        end)
    else
      new_promise:resolve(result)
    end
  end

  if self._resolved and not self._error then
    local schedule_then = vim.schedule_wrap(handle_callback)
    schedule_then(self._value)
  elseif self._resolved and self._error then
    new_promise:reject(self._error)
  else
    table.insert(self._then_callbacks, handle_callback)
    table.insert(self._catch_callbacks, function(err)
      new_promise:reject(err)
    end)
  end

  return new_promise
end

---@generic T
---@param self Promise<T>
---@param error_callback fun(err: any): any | Promise<any>
---@return Promise<T>
function Promise:catch(error_callback)
  local new_promise = Promise.new()

  local handle_error = function(err)
    local ok, result = pcall(error_callback, err)
    if not ok then
      new_promise:reject(result)
      return
    end

    -- If error callback returns a Promise, chain it
    if type(result) == 'table' and result.and_then then
      result
        :and_then(function(val)
          new_promise:resolve(val)
        end)
        :catch(function(e)
          new_promise:reject(e)
        end)
    else
      new_promise:resolve(result)
    end
  end

  local handle_success = function(value)
    new_promise:resolve(value)
  end

  if self._resolved and self._error then
    local schedule_catch = vim.schedule_wrap(handle_error)
    schedule_catch(self._error)
  elseif self._resolved and not self._error then
    new_promise:resolve(self._value)
  else
    table.insert(self._catch_callbacks, handle_error)
    table.insert(self._then_callbacks, handle_success)
  end

  return new_promise
end

---@generic T
---@param self Promise<T>
---@param timeout integer|nil Timeout in milliseconds (default: 5000)
---@param interval integer|nil Interval in milliseconds to check (default: 20)
---@return T
function Promise:wait(timeout, interval)
  if self._resolved then
    if self._error then
      error(self._error)
    end
    return self._value
  end

  timeout = timeout or 5000
  interval = interval or 20

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
