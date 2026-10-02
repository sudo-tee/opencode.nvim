---Central store for streamed server events, used for replay fixtures.
---Protocol adapters record protocol-specific event shapes here when
---`debug.capture_streamed_events` is enabled. Foundation module so Entry
---(debug_helper) and Infrastructure (protocols) can share it without a layer violation.
---@class OpencodeEventCapture
---@field events table[] Captured protocol-tagged events for debugging
local M = {
  events = {},
}

---Record one protocol-specific event when capture is enabled.
---@param event {type: string, protocol?: 'v1'|'v2', properties?: table, data?: table, created?: number, id?: string}
function M.record(event)
  local ok, config = pcall(require, 'opencode.config')
  if not ok or not config.debug or not config.debug.capture_streamed_events then
    return
  end
  if type(event) ~= 'table' or type(event.type) ~= 'string' then
    return
  end
  table.insert(M.events, vim.deepcopy(event))
end

---Borrow the captured events.
---@return table[]
function M.get()
  return M.events
end

---Discard all captured events.
function M.clear()
  M.events = {}
end

---Write captured events to a JSON file.
---@param filename? string Destination path, defaults to `data.json`
---@return integer|nil count Number of events saved, or nil when nothing was saved
function M.save(filename)
  filename = filename or 'data.json'
  if #M.events == 0 then
    vim.notify('No captured events to save', vim.log.levels.WARN)
    return nil
  end
  local json_str = vim.json.encode(M.events)
  vim.fn.writefile(vim.split(json_str, '\n'), filename)
  vim.notify(string.format('Saved %d events to %s', #M.events, filename), vim.log.levels.INFO)
  return #M.events
end

return M
