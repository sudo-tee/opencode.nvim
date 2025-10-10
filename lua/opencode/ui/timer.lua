---@class TimerOptions
---@field interval number The interval in milliseconds
---@field on_tick function The function to call on each tick
---@field on_stop? function The function to call when the timer stops
---@field repeat_timer? boolean Whether the timer should repeat (default: true)
---@field args? table Optional arguments to pass to the on_tick function

local Timer = {}
Timer.__index = Timer

--- Create a new Timer instance
---@param opts TimerOptions
function Timer.new(opts)
  local self = setmetatable({}, Timer)
  self.interval = opts.interval
  self.on_tick = opts.on_tick
  self.on_stop = opts.on_stop
  self.repeat_timer = opts.repeat_timer
  if self.repeat_timer == nil then
    self.repeat_timer = true
  end
  self.args = opts.args or {}
  self._uv_timer = nil
  return self
end

--- Start the timer (uses libuv/vim.loop for reliable scheduling)
function Timer:start()
  self:stop()
  local uv = vim.uv
  local timer = uv.new_timer()
  if not timer then
    self._uv_timer = nil
    error('failed to create uv timer')
  end
  self._uv_timer = timer

  local function on_tick_wrapped()
    local ok, continue = pcall(self.on_tick, unpack(self.args))
    if not ok then
      self:stop()
      return
    end
    if not self.repeat_timer or (continue ~= nil and continue == false) then
      self:stop()
    end
  end

  local cb = vim.schedule_wrap(on_tick_wrapped)

  local ok, err = pcall(function()
    if self.repeat_timer then
      timer:start(self.interval, self.interval, cb)
    else
      timer:start(self.interval, 0, cb)
    end
  end)
  if not ok then
    pcall(timer.close, timer)
    self._uv_timer = nil
    error(err)
  end
end

function Timer:stop()
  if self._uv_timer then
    pcall(self._uv_timer.stop, self._uv_timer)
    pcall(self._uv_timer.close, self._uv_timer)
    if self.on_stop then
      pcall(self.on_stop)
    end
    self._uv_timer = nil
  end
end

--- Check if the timer is running
function Timer:is_running()
  return self._uv_timer ~= nil
end

return Timer
