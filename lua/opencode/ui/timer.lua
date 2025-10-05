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
  self.handle = nil
  return self
end

--- Start the timer
function Timer:start()
  self:stop()
  local function tick()
    local continue = self.on_tick(unpack(self.args))
    if self.repeat_timer and (continue == nil or continue) then
      self.handle = vim.fn.timer_start(self.interval, tick)
    else
      self:stop()
    end
  end
  self.handle = vim.fn.timer_start(self.interval, tick)
end

--- Stop the timer
function Timer:stop()
  if self.handle then
    pcall(vim.fn.timer_stop, self.handle)
    if self.on_stop then
      self.on_stop()
    end
    self.handle = nil
  end
end

--- Check if the timer is running
function Timer:is_running()
  return self.handle ~= nil
end

return Timer
