---@class IdleDetector
---@field private _last_activity number Timestamp of last user activity in milliseconds
---@field private _timer uv_timer_t|nil Polling timer
---@field private _callback function|nil Callback to invoke when idle threshold exceeded
---@field private _threshold number Idle threshold in milliseconds
---@field private _check_interval number How often to check for idle state in milliseconds
---@field private _is_idle boolean Current idle state
---@field private _autocmd_group number|nil Autocmd group ID
local IdleDetector = {}
IdleDetector.__index = IdleDetector

---Creates a new idle detector instance
---@param opts {threshold: number, callback: function, check_interval?: number}
---@return IdleDetector
function IdleDetector.new(opts)
  local self = setmetatable({}, IdleDetector)
  self._threshold = opts.threshold or 10000 -- Default 10 seconds
  self._callback = opts.callback
  self._check_interval = opts.check_interval or 1000 -- Default 1 second polling
  self._last_activity = vim.loop.now()
  self._is_idle = false
  self._timer = nil
  self._autocmd_group = nil
  return self
end

---Marks that user activity occurred
---@private
function IdleDetector:_record_activity()
  self._last_activity = vim.loop.now()
  if self._is_idle then
    self._is_idle = false
  end
end

---Checks if idle threshold has been exceeded
---@private
function IdleDetector:_check_idle()
  local now = vim.loop.now()
  local elapsed = now - self._last_activity
  
  if not self._is_idle and elapsed >= self._threshold then
    self._is_idle = true
    if self._callback then
      -- Schedule callback to run in main event loop
      vim.schedule(function()
        self._callback()
      end)
    end
  end
end

---Starts the idle detection
function IdleDetector:start()
  if self._timer then
    return -- Already started
  end
  
  -- Create autocmd group for activity tracking
  self._autocmd_group = vim.api.nvim_create_augroup('OpenCodeIdleDetector', { clear = true })
  
  -- Track all relevant user activity events
  local activity_events = {
    'CursorMoved',
    'CursorMovedI',
    'InsertEnter',
    'InsertLeave',
    'TextChanged',
    'TextChangedI',
    'CmdlineEnter',
    'WinEnter',
    'BufEnter',
  }
  
  for _, event in ipairs(activity_events) do
    vim.api.nvim_create_autocmd(event, {
      group = self._autocmd_group,
      callback = function()
        self:_record_activity()
      end,
    })
  end
  
  -- Ensure timer is stopped on Neovim exit to prevent hanging
  vim.api.nvim_create_autocmd({ 'VimLeavePre', 'QuitPre' }, {
    group = self._autocmd_group,
    once = true,
    callback = function()
      self:stop()
    end,
  })
  
  -- Create polling timer to check for idle state
  self._timer = vim.loop.new_timer()
  if self._timer then
    self._timer:start(
      self._check_interval, -- Initial delay
      self._check_interval, -- Repeat interval
      vim.schedule_wrap(function()
        self:_check_idle()
      end)
    )
  end
end

---Stops the idle detection
function IdleDetector:stop()
  if self._timer then
    self._timer:stop()
    self._timer:close()
    self._timer = nil
  end
  
  if self._autocmd_group then
    vim.api.nvim_del_augroup_by_id(self._autocmd_group)
    self._autocmd_group = nil
  end
  
  self._is_idle = false
end

---Updates the idle threshold
---@param threshold number New threshold in milliseconds
function IdleDetector:set_threshold(threshold)
  self._threshold = threshold
end

---Updates the callback function
---@param callback function New callback function
function IdleDetector:set_callback(callback)
  self._callback = callback
end

---Returns current idle state
---@return boolean
function IdleDetector:is_idle()
  return self._is_idle
end

---Returns time since last activity in milliseconds
---@return number
function IdleDetector:time_since_activity()
  return vim.loop.now() - self._last_activity
end

return IdleDetector
