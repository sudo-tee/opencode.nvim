---@class TimerOptions
---@field interval number The interval in milliseconds
---@field on_tick function The function to call on each tick
---@field on_stop? function The function to call when the timer stops
---@field repeat_timer? boolean Whether the timer should repeat (default: true)
---@field args? table Optional arguments to pass to the on_tick function

local Timer = {}
Timer.__index = Timer

---@param opts TimerOptions
function Timer.new(opts)
  local self = setmetatable({}, Timer)
  self.interval = opts.interval
  self.on_tick = opts.on_tick
  self.on_stop = opts.on_stop
  self.repeat_timer = opts.repeat_timer ~= false
  self.args = opts.args or {}
  self._uv_timer = nil
  return self
end

function Timer:start()
  self:stop()

  local timer = vim.uv.new_timer()
  if not timer then
    error('failed to create uv timer')
  end
  self._uv_timer = timer

  local on_tick = vim.schedule_wrap(function()
    local ok, continue = pcall(self.on_tick, unpack(self.args))
    if not ok or not self.repeat_timer or (continue == false) then
      self:stop()
    end
  end)

  local ok, err = pcall(function()
    local repeat_interval = self.repeat_timer and self.interval or 0
    timer:start(self.interval, repeat_interval, on_tick)
  end)

  if not ok then
    pcall(timer.close, timer)
    self._uv_timer = nil
    error(err)
  end
end

--- Start the timer and immediately execute the callback
function Timer:start_and_tick()
  self:start()
  self.on_tick(unpack(self.args))
end

function Timer:stop()
  if not self._uv_timer then
    return
  end

  pcall(self._uv_timer.stop, self._uv_timer)
  pcall(self._uv_timer.close, self._uv_timer)
  self._uv_timer = nil

  if self.on_stop then
    pcall(self.on_stop)
  end
end

function Timer:is_running()
  return self._uv_timer ~= nil
end

return Timer
