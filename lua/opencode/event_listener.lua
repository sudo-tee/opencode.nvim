local curl = require('plenary.curl')
local util = require('opencode.util')

---@class EventListener
local EventListener = {}
EventListener.__index = EventListener

function EventListener.new()
  return setmetatable({
    connection = nil,
    handlers = {},
    running = false,
    base_url = nil,
    buffer = '',
  }, EventListener)
end

function EventListener:on(event_type, callback)
  if not self.handlers[event_type] then
    self.handlers[event_type] = {}
  end
  table.insert(self.handlers[event_type], callback)
end

function EventListener:off(event_type, callback)
  if not self.handlers[event_type] then
    return
  end
  for i, cb in ipairs(self.handlers[event_type]) do
    if cb == callback then
      table.remove(self.handlers[event_type], i)
      return
    end
  end
end

local function parse_sse_event(data)
  local lines = vim.split(data, '\n', { plain = true })
  local event_type = nil
  local event_data = nil

  for _, line in ipairs(lines) do
    if line:match('^event:%s*(.+)') then
      event_type = line:match('^event:%s*(.+)')
    elseif line:match('^data:%s*(.+)') then
      local data_str = line:match('^data:%s*(.+)')
      local ok, parsed = pcall(vim.json.decode, data_str)
      if ok then
        event_data = parsed
      end
    end
  end

  return event_type, event_data
end

function EventListener:_emit(event_type, data)
  vim.schedule(function()
    vim.notify('📡 SSE Event: ' .. event_type, vim.log.levels.INFO)
  end)
  
  if self.handlers[event_type] then
    for _, callback in ipairs(self.handlers[event_type]) do
      util.safe_call(callback, data)
    end
  end
  if self.handlers['*'] then
    for _, callback in ipairs(self.handlers['*']) do
      util.safe_call(callback, event_type, data)
    end
  end
end

function EventListener:start(base_url)
  if self.running then
    return
  end

  self.running = true
  self.base_url = base_url
  self.buffer = ''

  local event_url = base_url .. '/event'

  vim.schedule(function()
    if not self.running then
      return
    end

    local ok, result = pcall(curl.get, event_url, {
      stream = vim.schedule_wrap(function(err, chunk)
        if not self.running then
          return
        end

        if err then
          if self.running then
            self:_emit('error', { message = err })
          end
          return
        end

        if not chunk or chunk == '' then
          return
        end

        self.buffer = self.buffer .. chunk

        local double_newline_pos = self.buffer:find('\n\n', 1, true)
        while double_newline_pos do
          local event_block = self.buffer:sub(1, double_newline_pos - 1)
          self.buffer = self.buffer:sub(double_newline_pos + 2)

          if event_block ~= '' then
            local event_type, event_data = parse_sse_event(event_block)
            if event_type and self.running then
              self:_emit(event_type, event_data)
            end
          end

          double_newline_pos = self.buffer:find('\n\n', 1, true)
        end
      end),
      on_error = vim.schedule_wrap(function(err)
        if self.running then
          self:_emit('error', { message = err.message or vim.inspect(err) })
          self.running = false
        end
      end),
    })

    if ok then
      self.connection = result
    else
      self.running = false
    end
  end)
end

function EventListener:stop()
  if not self.running then
    return
  end

  self.running = false
  self.buffer = ''

  if self.connection then
    pcall(function()
      if self.connection.close then
        self.connection:close()
      end
    end)
    self.connection = nil
  end
end

return EventListener
