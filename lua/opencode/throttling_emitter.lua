local M = {}

--- @class ThrottlingEmitter
--- @field queue table[] Queue of pending items to be processed
--- @field drain_scheduled boolean Whether a drain is already scheduled
--- @field process_fn fun(table): nil Function to process the queue of events
--- @field drain_interval_ms integer Interval between drains in milliseconds
--- @field enqueue fun(self: ThrottlingEmitter, item: any) Enqueue an item for batch processing
--- @field clear fun(self: ThrottlingEmitter) Clear the queue and cancel any pending drain
local ThrottlingEmitter = {}
ThrottlingEmitter.__index = ThrottlingEmitter

--- Create a new ThrottlingEmitter instance. This emitter collects events and
--- then drains them every drain_interval_ms milliseconds. This is helpful to
--- make sure we're not generating so many events that we don't overwhelm
--- neovim, particularly treesitter.
--- @param process_fn function Function to call for each item
--- @param drain_interval_ms number? Interval between drains in milliseconds (default 40)
--- @return ThrottlingEmitter
function M.new(process_fn, drain_interval_ms)
  return setmetatable({
    queue = {},
    drain_scheduled = false,
    _generation = 0,
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
    local generation = self._generation
    vim.defer_fn(function()
      if generation ~= self._generation then
        return
      end
      self:_drain()
    end, self.drain_interval_ms)
  end
end

--- Process all queued items
function ThrottlingEmitter:_drain()
  self.drain_scheduled = false

  local items_to_process = self.queue
  self.queue = {}

  if #items_to_process > 0 then
    self.process_fn(items_to_process)
  end
end

--- Clear the queue and cancel any pending drain
function ThrottlingEmitter:clear()
  self._generation = self._generation + 1
  self.queue = {}
  self.drain_scheduled = false
end

return M
