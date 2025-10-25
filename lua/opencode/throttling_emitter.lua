local M = {}

--- @class ThrottlingEmitter
--- @field queue table[] Queue of pending items to be processed
--- @field drain_scheduled boolean Whether a drain is already scheduled
--- @field process_fn fun(table): nil Function to process the queue of events
--- @field drain_interval_ms number Interval between drains in milliseconds
--- @field enqueue fun(self: ThrottlingEmitter, item: any) Enqueue an item for batch processing
--- @field clear fun(self: ThrottlingEmitter) Clear the queue and cancel any pending drain
local ThrottlingEmitter = {}
ThrottlingEmitter.__index = ThrottlingEmitter

--- Create a new ThrottlingEmitter instance. This emitter collects events and
--- then drains them every drain_interval_ms milliseconds. This is helpful to
--- make sure we're not generating so many events that we don't overwhelm
--- neovim, particularly treesitter.
--- @param process_fn function Function to call for each item
--- @param drain_interval_ms number? Interval between drains in milliseconds (default 10)
--- @return ThrottlingEmitter
function M.new(process_fn, drain_interval_ms)
  return setmetatable({
    queue = {},
    drain_scheduled = false,
    process_fn = process_fn,
    drain_interval_ms = drain_interval_ms or 40,
  }, ThrottlingEmitter)
end

--- Enqueue an item for batch processing
--- @param item any The item to enqueue
function ThrottlingEmitter:enqueue(item)
  table.insert(self.queue, item)

  if not self.drain_scheduled then
    self.drain_scheduled = true
    vim.defer_fn(function()
      self:_drain()
    end, self.drain_interval_ms)
  end
end

--- Process all queued items
function ThrottlingEmitter:_drain()
  self.drain_scheduled = false

  local items_to_process = self.queue
  self.queue = {}

  self.process_fn(items_to_process)

  -- double check that items weren't added while processing
  if #self.queue > 0 and not self.drain_scheduled then
    self.drain_scheduled = true
    vim.defer_fn(function()
      self:_drain()
    end, self.drain_interval_ms)
  end
  -- end)
end

--- Clear the queue and cancel any pending drain
function ThrottlingEmitter:clear()
  self.queue = {}
  self.drain_scheduled = false
end

return M
