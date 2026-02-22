---@generic T
---@generic U
---@class Promise<T>
---@field __index Promise<T>
---@field _resolved boolean
---@field _value T
---@field _error any
---@field _then_callbacks fun(value: T)[]
---@field _catch_callbacks fun(err: any)[]
---@field _coroutines thread[]
---@field new fun(): Promise<T>
---@field resolve fun(self: Promise<T>, value: T): Promise<T>
---@field reject fun(self: Promise<T>, err: any): Promise<T>
---@field and_then fun(self: Promise<T>, callback: fun(value: T): U | Promise<U> | nil): Promise<U>
---@field catch fun(self: Promise<T>, error_callback: fun(err: any): any | Promise<any> | nil): Promise<T>
---@field finally fun(self: Promise<T>, callback: fun(): nil): Promise<T>
---@field wait fun(self: Promise<T>, timeout?: integer, interval?: integer): T
---@field peek fun(self: Promise<T>): T
---@field is_resolved fun(self: Promise<T>): boolean
---@field is_rejected fun(self: Promise<T>): boolean
---@field await fun(self: Promise<T>): T
---@field is_promise fun(obj: any): boolean
---@field wrap fun(obj: T | Promise<T>): Promise<T>
---@field spawn fun(fn: fun(): T|nil): Promise<T>
---@field async fun(fn: fun(...): T?): fun(...): Promise<T>
---@field system fun(table, table): Promise<T>
local Promise = {}
Promise.__index = Promise

---Resume waiting coroutines with result
---@generic T
---@param coroutines thread[]
---@param value T
---@param err any
local function resume_coroutines(coroutines, value, err)
  for _, co in ipairs(coroutines) do
    vim.schedule(function()
      if coroutine.status(co) == 'suspended' then
        coroutine.resume(co, value, err)
      end
    end)
  end
end

---Create a waitable promise that can be resolved or rejected later
---@return Promise<T>
function Promise.new()
  local self = setmetatable({
    _resolved = false,
    _value = nil,
    _error = nil,
    _then_callbacks = {},
    _catch_callbacks = {},
    _coroutines = {},
  }, Promise)
  return self
end

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

  resume_coroutines(self._coroutines, value, nil)

  return self
end

---@param err any
---@return Promise<T>
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

  resume_coroutines(self._coroutines, nil, err)

  return self
end

---@generic U
---@param callback fun(value: T): U | Promise<U> | nil
---@return Promise<U>?
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

    if Promise.is_promise(result) then
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

---@param error_callback fun(err: any): any | Promise<any> | nil
---@return Promise<T>
function Promise:catch(error_callback)
  local new_promise = Promise.new()

  local handle_error = function(err)
    local ok, result = pcall(error_callback, err)
    if not ok then
      new_promise:reject(result)
      return
    end

    if Promise.is_promise(result) then
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

---Execute a callback regardless of whether the promise resolves or rejects
---The callback is called without any arguments and its return value is ignored
---@param callback fun(): nil
---@return Promise<T>
function Promise:finally(callback)
  local new_promise = Promise.new()

  local handle_finally = function()
    local ok, err = pcall(callback)
    -- Ignore callback errors and result, finally doesn't change the promise chain
    if not ok then
      -- Log error but don't propagate it
      vim.notify('Error in finally callback: ' .. tostring(err), vim.log.levels.WARN)
    end
  end

  local handle_success = function(value)
    handle_finally()
    new_promise:resolve(value)
  end

  local handle_error = function(err)
    handle_finally()
    new_promise:reject(err)
  end

  if self._resolved and not self._error then
    -- Promise already resolved successfully
    local schedule_finally = vim.schedule_wrap(handle_success)
    schedule_finally(self._value)
  elseif self._resolved and self._error then
    -- Promise already rejected
    local schedule_finally = vim.schedule_wrap(handle_error)
    schedule_finally(self._error)
  else
    -- Promise still pending, add callbacks
    table.insert(self._then_callbacks, handle_success)
    table.insert(self._catch_callbacks, handle_error)
  end

  return new_promise
end

--- Synchronously wait for the promise to resolve or reject
--- This will block the main thread, so use with caution
--- But is useful for synchronous code paths that need the result
---@generic T
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

-- Tries to get the value without waiting
-- Useful for status checks where you don't want to block
---@generic T
---@return T
function Promise:peek()
  return self._value
end

function Promise:is_resolved()
  return self._resolved
end

function Promise:is_rejected()
  return self._resolved and self._error ~= nil
end

---Await the promise from within a coroutine
---This function can only be called from within `coroutine.create` or `Promise.spawn` or `Promise.async`
---This will yield the coroutine until the promise resolves or rejects
---@generic T
---@return T
function Promise:await()
  -- If already resolved, return immediately
  local value
  if self._resolved then
    if self._error then
      error(self._error)
    end
    value = self._value
    ---@cast value T
    return value
  end

  -- Get the current coroutine
  local co = coroutine.running()
  if not co then
    error('await() can only be called from within a coroutine')
  end

  table.insert(self._coroutines, co)

  -- Yield and wait for resume
  ---@diagnostic disable-next-line: await-in-sync
  local value, err = coroutine.yield()

  if err then
    error(err)
  end

  ---@cast value T
  return value
end

---@param obj any
---@return_cast obj Promise<T>
function Promise.is_promise(obj)
  return type(obj) == 'table' and type(obj.and_then) == 'function' and type(obj.catch) == 'function'
end

---@param obj T | Promise<T>
---@return Promise<T>
---@return_cast T Promise<T>
function Promise.wrap(obj)
  if Promise.is_promise(obj) then
    return obj --[[@as Promise<T>]]
  else
    return Promise.new():resolve(obj)
  end
end

---Run an async function in a coroutine
---The function can use promise:await() to wait for promises
---@generic T
---@param fn fun(): T
---@return Promise<T>
---@return_cast T Promise<T>
function Promise.spawn(fn)
  local promise = Promise.new()

  local co = coroutine.create(function()
    local ok, result = pcall(fn)
    if not ok then
      promise:reject(result)
    else
      if Promise.is_promise(result) then
        result
          :and_then(function(val)
            promise:resolve(val)
          end)
          :catch(function(err)
            promise:reject(err)
          end)
      else
        promise:resolve(result)
      end
    end
  end)

  local ok, err = coroutine.resume(co)
  if not ok then
    promise:reject(err)
  end

  return promise
end

---Wrap a function to run asynchronously
---Takes a function and returns a wrapped version that returns a Promise
---@generic T
---@param fn fun(...): T
---@return fun(...): Promise<T>
function Promise.async(fn)
  return function(...)
    -- Capture both args and count to handle nil values correctly
    local n = select('#', ...)
    local args = { ... }
    return Promise.spawn(function()
      return fn(unpack(args, 1, n))
    end)
  end
end

---Wrap vim.system in a promise
---@generic T
---@param cmd table vim.system cmd options
---@param opts table|nil vim.system opts
---@return Promise<T>
function Promise.system(cmd, opts)
  local p = Promise.new()

  vim.system(cmd, opts or {}, function(result)
    if result.code == 0 then
      p:resolve(result)
    else
      p:reject(result)
    end
  end)

  return p
end

---Wait for all promises to resolve
---Returns a promise that resolves with a table of all results
---If any promise rejects, the returned promise rejects with that error
---@generic T
---@param promises Promise<T>[]
---@return Promise<T[]>
function Promise.all(promises)
  return Promise.spawn(function()
    local results = {}
    for i, promise in ipairs(promises) do
      results[i] = promise:await()
    end
    return results
  end)
end

return Promise
