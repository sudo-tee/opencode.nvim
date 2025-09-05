---@generic T
---@class Promise<T>
---@field and_then fun(self: Promise, callback: fun(value: any)): Promise
---@field resolve fun(self: Promise, value: any): Promise
---@field reject fun(self: Promise, err: any): Promise
---@field catch fun(self: Promise, callback: fun(err: any)): Promise
---@field wait fun(self: Promise, timeout?: integer, interval?: integer): any
---@field is_resolved fun(self: Promise): boolean
---@field is_rejected fun(self: Promise): boolean
---@field _resolved boolean
---@field _value any
---@field _error any
---@field _then_callbacks fun(value: any)[]
---@field _catch_callbacks fun(err: any)[]
local M = {}

---Create a waitable promise that can be resolved or rejected later
---@return Promise
function M.new()
  local schedule_then = vim.schedule_wrap(function(cb, value)
    cb(value)
  end)
  local schedule_catch = vim.schedule_wrap(function(cb, err)
    cb(err)
  end)

  ---@type Promise
  local promise = {
    _resolved = false,
    _value = nil,
    _error = nil,
    _then_callbacks = {},
    _catch_callbacks = {},
  }

  ---@param self Promise
  ---@param value any
  ---@return Promise
  function promise:resolve(value)
    if self._resolved then
      return self
    end
    self._value = value
    self._resolved = true

    for _, callback in ipairs(self._then_callbacks) do
      schedule_then(callback, value)
    end
    return self
  end

  ---@param self Promise
  ---@param error any
  ---@return Promise
  function promise:reject(error)
    if self._resolved then
      return self
    end
    self._error = error
    self._resolved = true

    for _, callback in ipairs(self._catch_callbacks) do
      schedule_catch(callback, error)
    end
    return self
  end

  ---@param self Promise
  ---@param callback fun(value: any)
  ---@return Promise
  function promise:and_then(callback)
    if not callback then
      error('callback is required')
    end
    if self._resolved and not self._error then
      schedule_then(callback, self._value)
    else
      table.insert(self._then_callbacks, callback)
    end
    return self
  end

  ---@param self Promise
  ---@param error_callback fun(err: any)
  ---@return Promise
  function promise:catch(error_callback)
    if self._resolved and self._error then
      schedule_catch(error_callback, self._error)
    else
      table.insert(self._catch_callbacks, error_callback)
    end
    return self
  end

  ---@param self Promise
  ---@param timeout integer|nil Timeout in milliseconds (default: 5000)
  ---@param interval integer|nil Interval in milliseconds to check (default: 100)
  ---@return any
  function promise:wait(timeout, interval)
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

  function promise:is_resolved()
    return self._resolved
  end

  function promise:is_rejected()
    return self._resolved and self._error ~= nil
  end

  return promise
end

return M
