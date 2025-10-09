-- TTL-based cache for context sections
-- Provides per-section caching with configurable TTL and async job management
--

local M = {}

-- Cache structure: { [section_name] = { timestamp = number, data = any, job_id = number|nil } }
M.cache = {}

-- Default TTL in milliseconds (5 seconds)
M.DEFAULT_TTL = 5000

-- Async job tracking
M.jobs = {}

---Check if cached data is still valid
---@param section_name string
---@param ttl? number TTL in milliseconds (defaults to DEFAULT_TTL)
---@return boolean
function M.is_valid(section_name, ttl)
  ttl = ttl or M.DEFAULT_TTL
  local cached = M.cache[section_name]
  if not cached then
    return false
  end

  local now = vim.loop.hrtime() / 1e6 -- Convert to milliseconds
  return (now - cached.timestamp) < ttl
end

---Get cached data if valid
---@param section_name string
---@param ttl? number TTL in milliseconds
---@return any|nil
function M.get(section_name, ttl)
  if M.is_valid(section_name, ttl) then
    return M.cache[section_name].data
  end
  return nil
end

---Set cached data
---@param section_name string
---@param data any
function M.set(section_name, data)
  local now = vim.loop.hrtime() / 1e6
  M.cache[section_name] = {
    timestamp = now,
    data = data,
    job_id = nil,
  }
end

---Clear specific cache entry
---@param section_name string
function M.clear(section_name)
  M.cache[section_name] = nil
end

---Clear all cache
function M.clear_all()
  M.cache = {}
  M.jobs = {}
end

---Start async job for expensive operation
---@param section_name string
---@param cmd string|table Command to execute
---@param callback function(data: any) Called with result
---@param opts? table Options: { timeout: number, on_error: function }
function M.start_job(section_name, cmd, callback, opts)
  opts = opts or {}
  local timeout = opts.timeout or 5000

  -- Cancel existing job if any
  if M.jobs[section_name] then
    vim.fn.jobstop(M.jobs[section_name])
  end

  local output = {}
  local job_id = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        vim.list_extend(output, data)
      end
    end,
    on_stderr = function(_, data)
      if opts.on_error and data and #data > 0 then
        opts.on_error(data)
      end
    end,
    on_exit = function(_, exit_code)
      M.jobs[section_name] = nil
      if exit_code == 0 then
        local result = table.concat(output, '\n')
        callback(result)
      elseif opts.on_error then
        opts.on_error({ 'Job failed with exit code: ' .. exit_code })
      end
    end,
  })

  M.jobs[section_name] = job_id

  -- Set timeout
  vim.defer_fn(function()
    if M.jobs[section_name] == job_id then
      vim.fn.jobstop(job_id)
      M.jobs[section_name] = nil
      if opts.on_error then
        opts.on_error({ 'Job timeout after ' .. timeout .. 'ms' })
      end
    end
  end, timeout)

  return job_id
end

---Execute multiple jobs in parallel and call callback when all complete
---@param tasks table[] Array of { name: string, cmd: string|table, ttl?: number }
---@param callback function(results: table) Called with { [name] = data }
---@param opts? table Options: { timeout: number }
function M.parallel(tasks, callback, opts)
  opts = opts or {}
  local results = {}
  local pending = #tasks
  local completed = false

  if pending == 0 then
    callback(results)
    return
  end

  for _, task in ipairs(tasks) do
    local name = task.name

    -- Check cache first
    local cached = M.get(name, task.ttl)
    if cached then
      results[name] = cached
      pending = pending - 1
      if pending == 0 and not completed then
        completed = true
        vim.schedule(function()
          callback(results)
        end)
      end
    else
      -- Start async job
      M.start_job(name, task.cmd, function(data)
        results[name] = data
        M.set(name, data)
        pending = pending - 1

        if pending == 0 and not completed then
          completed = true
          vim.schedule(function()
            callback(results)
          end)
        end
      end, {
        timeout = opts.timeout or 3000,
        on_error = function(err)
          results[name] = nil
          pending = pending - 1

          if pending == 0 and not completed then
            completed = true
            vim.schedule(function()
              callback(results)
            end)
          end
        end,
      })
    end
  end
end

---Get cache statistics
---@return table { total: number, by_section: table }
function M.stats()
  local stats = { total = 0, by_section = {} }
  local now = vim.loop.hrtime() / 1e6

  for section, cached in pairs(M.cache) do
    local age = now - cached.timestamp
    stats.by_section[section] = {
      age_ms = age,
      valid = age < M.DEFAULT_TTL,
      has_data = cached.data ~= nil,
    }
    stats.total = stats.total + 1
  end

  return stats
end

return M
