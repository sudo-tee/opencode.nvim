local state = require('opencode.state')
local config = require('opencode.config')
local ThrottlingEmitter = require('opencode.throttling_emitter')

--- @class EventInstallationUpdated
--- @field type "installation.updated"
--- @field properties {version: string}

--- @class EventLspClientDiagnostics
--- @field type "lsp.client.diagnostics"
--- @field properties {serverID: string, path: string}

--- @class EventMessageUpdated
--- @field type "message.updated"
--- @field properties {info: MessageInfo}

--- @class EventMessageRemoved
--- @field type "message.removed"
--- @field properties {sessionID: string, messageID: string}

--- @class EventMessagePartUpdated
--- @field type "message.part.updated"
--- @field properties {part: OpencodeMessagePart}

--- @class EventMessagePartRemoved
--- @field type "message.part.removed"
--- @field properties {sessionID: string, messageID: string, partID: string}

--- @class EventSessionCompacted
--- @field type "session.compacted"
--- @field properties {sessionID: string}

--- @class EventSessionIdle
--- @field type "session.idle"
--- @field properties {sessionID: string}

--- @class EventSessionUpdated
--- @field type "session.updated"
--- @field properties {info: Session}

--- @class EventSessionDeleted
--- @field type "session.deleted"
--- @field properties {info: Session}

--- @class EventSessionError
--- @field type "session.error"
--- @field properties {sessionID: string, error: table}

--- @class OpencodePermission
--- @field id string
--- @field type string
--- @field pattern string|string[]
--- @field sessionID string
--- @field messageID string
--- @field callID? string
--- @field title string
--- @field metadata table
--- @field time {created: number}

--- @class EventPermissionUpdated
--- @field type "permission.updated"
--- @field properties OpencodePermission

--- @class EventPermissionReplied
--- @field type "permission.replied"
--- @field properties {sessionID: string, permissionID: string, response: string}

--- @class EventFileEdited
--- @field type "file.edited"
--- @field properties {file: string}

--- @class EventFileWatcherUpdated
--- @field type "file.watcher.updated"
--- @field properties {file: string, event: "add"|"change"|"unlink"}

--- @class EventServerConnected
--- @field type "server.connected"
--- @field properties table

--- @class EventIdeInstalled
--- @field type "ide.installed"
--- @field properties {ide: string}

--- @class ServerStartingEvent
--- @field server_job table

--- @class ServerReadyEvent
--- @field server_job table
--- @field url string

--- @class ServerStoppedEvent

--- @class RestorePointCreatedEvent
--- @field restore_point RestorePoint

--- @alias OpencodeEventName
--- | "installation.updated"
--- | "lsp.client.diagnostics"
--- | "message.updated"
--- | "message.removed"
--- | "message.part.updated"
--- | "message.part.removed"
--- | "session.compacted"
--- | "session.idle"
--- | "session.updated"
--- | "session.deleted"
--- | "session.error"
--- | "permission.updated"
--- | "permission.replied"
--- | "file.edited"
--- | "file.watcher.updated"
--- | "server.connected"
--- | "ide.installed"
--- | "custom.server_starting"
--- | "custom.server_ready"
--- | "custom.server_stopped"
--- | "custom.restore_point.created"
--- | "custom.emit_events.started"
--- | "custom.emit_events.finished"

--- @class EventManager
--- @field events table<string, function[]> Event listener registry
--- @field server_subscription table|nil Subscription to server events
--- @field is_started boolean Whether the event manager is started
--- @field captured_events table[] List of captured events for debugging
--- @field throttling_emitter ThrottlingEmitter Throttle instance for batching events
local EventManager = {}
EventManager.__index = EventManager

--- Create a new EventManager instance
--- @return EventManager
function EventManager.new()
  local self = setmetatable({
    events = {},
    server_subscription = nil,
    is_started = false,
    captured_events = {},
  }, EventManager)

  local throttle_ms = config.ui.output.rendering.event_throttle_ms
  self.throttling_emitter = ThrottlingEmitter.new(function(events)
    self:_on_drained_events(events)
  end, throttle_ms)

  return self
end

--- Subscribe to an event with type-safe callbacks using function overloads
--- @overload fun(self: EventManager, event_name: "installation.updated", callback: fun(data: EventInstallationUpdated['properties']): nil)
--- @overload fun(self: EventManager, event_name: "lsp.client.diagnostics", callback: fun(data: EventLspClientDiagnostics['properties']): nil)
--- @overload fun(self: EventManager, event_name: "message.updated", callback: fun(data: EventMessageUpdated['properties']): nil)
--- @overload fun(self: EventManager, event_name: "message.removed", callback: fun(data: EventMessageRemoved['properties']): nil)
--- @overload fun(self: EventManager, event_name: "message.part.updated", callback: fun(data: EventMessagePartUpdated['properties']): nil)
--- @overload fun(self: EventManager, event_name: "message.part.removed", callback: fun(data: EventMessagePartRemoved['properties']): nil)
--- @overload fun(self: EventManager, event_name: "session.compacted", callback: fun(data: EventSessionCompacted['properties']): nil)
--- @overload fun(self: EventManager, event_name: "session.idle", callback: fun(data: EventSessionIdle['properties']): nil)
--- @overload fun(self: EventManager, event_name: "session.updated", callback: fun(data: EventSessionUpdated['properties']): nil)
--- @overload fun(self: EventManager, event_name: "session.deleted", callback: fun(data: EventSessionDeleted['properties']): nil)
--- @overload fun(self: EventManager, event_name: "session.error", callback: fun(data: EventSessionError['properties']): nil)
--- @overload fun(self: EventManager, event_name: "permission.updated", callback: fun(data: EventPermissionUpdated['properties']): nil)
--- @overload fun(self: EventManager, event_name: "permission.replied", callback: fun(data: EventPermissionReplied['properties']): nil)
--- @overload fun(self: EventManager, event_name: "file.edited", callback: fun(data: EventFileEdited['properties']): nil)
--- @overload fun(self: EventManager, event_name: "file.watcher.updated", callback: fun(data: EventFileWatcherUpdated['properties']): nil)
--- @overload fun(self: EventManager, event_name: "server.connected", callback: fun(data: EventServerConnected['properties']): nil)
--- @overload fun(self: EventManager, event_name: "ide.installed", callback: fun(data: EventIdeInstalled['properties']): nil)
--- @overload fun(self: EventManager, event_name: "custom.server_starting", callback: fun(data: ServerStartingEvent['properties']): nil)
--- @overload fun(self: EventManager, event_name: "custom.server_ready", callback: fun(data: ServerReadyEvent['properties']): nil)
--- @overload fun(self: EventManager, event_name: "custom.server_stopped", callback: fun(data: ServerStoppedEvent['properties']): nil)
--- @overload fun(self: EventManager, event_name: "custom.restore_point.created", callback: fun(data: RestorePointCreatedEvent['properties']): nil)
--- @overload fun(self: EventManager, event_name: "custom.emit_events.started", callback: fun(): nil)
--- @overload fun(self: EventManager, event_name: "custom.emit_events.finished", callback: fun(): nil)
--- @param event_name OpencodeEventName The event name to listen for
--- @param callback function Callback function to execute when event is triggered
function EventManager:subscribe(event_name, callback)
  if not self.events[event_name] then
    self.events[event_name] = {}
  end
  table.insert(self.events[event_name], callback)
end

--- Unsubscribe from an event with type-safe callbacks using function overloads
--- @overload fun(self: EventManager, event_name: "installation.updated", callback: fun(data: EventInstallationUpdated['properties']): nil)
--- @overload fun(self: EventManager, event_name: "lsp.client.diagnostics", callback: fun(data: EventLspClientDiagnostics['properties']): nil)
--- @overload fun(self: EventManager, event_name: "message.updated", callback: fun(data: EventMessageUpdated['properties']): nil)
--- @overload fun(self: EventManager, event_name: "message.removed", callback: fun(data: EventMessageRemoved['properties']): nil)
--- @overload fun(self: EventManager, event_name: "message.part.updated", callback: fun(data: EventMessagePartUpdated['properties']): nil)
--- @overload fun(self: EventManager, event_name: "message.part.removed", callback: fun(data: EventMessagePartRemoved['properties']): nil)
--- @overload fun(self: EventManager, event_name: "session.compacted", callback: fun(data: EventSessionCompacted['properties']): nil)
--- @overload fun(self: EventManager, event_name: "session.idle", callback: fun(data: EventSessionIdle['properties']): nil)
--- @overload fun(self: EventManager, event_name: "session.updated", callback: fun(data: EventSessionUpdated['properties']): nil)
--- @overload fun(self: EventManager, event_name: "session.deleted", callback: fun(data: EventSessionDeleted['properties']): nil)
--- @overload fun(self: EventManager, event_name: "session.error", callback: fun(data: EventSessionError['properties']): nil)
--- @overload fun(self: EventManager, event_name: "permission.updated", callback: fun(data: EventPermissionUpdated['properties']): nil)
--- @overload fun(self: EventManager, event_name: "permission.replied", callback: fun(data: EventPermissionReplied['properties']): nil)
--- @overload fun(self: EventManager, event_name: "file.edited", callback: fun(data: EventFileEdited['properties']): nil)
--- @overload fun(self: EventManager, event_name: "file.watcher.updated", callback: fun(data: EventFileWatcherUpdated['properties']): nil)
--- @overload fun(self: EventManager, event_name: "server.connected", callback: fun(data: EventServerConnected['properties']): nil)
--- @overload fun(self: EventManager, event_name: "ide.installed", callback: fun(data: EventIdeInstalled['properties']): nil)
--- @overload fun(self: EventManager, event_name: "custom.server_starting", callback: fun(data: ServerStartingEvent['properties']): nil)
--- @overload fun(self: EventManager, event_name: "custom.server_ready", callback: fun(data: ServerReadyEvent['properties']): nil)
--- @overload fun(self: EventManager, event_name: "custom.server_stopped", callback: fun(data: ServerStoppedEvent['properties']): nil)
--- @overload fun(self: EventManager, event_name: "custom.restore_point.created", callback: fun(data: RestorePointCreatedEvent['properties']): nil)
--- @overload fun(self: EventManager, event_name: "custom.emit_events.started", callback: fun(): nil)
--- @overload fun(self: EventManager, event_name: "custom.emit_events.finished", callback: fun(): nil)
--- @param event_name OpencodeEventName The event name
--- @param callback function The callback function to remove
function EventManager:unsubscribe(event_name, callback)
  local listeners = self.events[event_name]
  if not listeners then
    return
  end

  for i, cb in ipairs(listeners) do
    if cb == callback then
      table.remove(listeners, i)
      break
    end
  end
end

---Callback from ThrottlingEmitter when the events are now ready to be processed.
---Collapses parts that are duplicated, making sure to replace earlier parts with later
---ones (but keeping the earlier position)
---@param events any
function EventManager:_on_drained_events(events)
  self:emit('custom.emit_events.started', {})

  local collapsed_events = {}
  local part_update_indices = {}

  for i, event in ipairs(events) do
    if event.type == 'message.part.updated' and event.properties.part then
      local part_id = event.properties.part.id
      if part_update_indices[part_id] then
        -- vim.notify('collapsing: ' .. part_id .. ' text: ' .. vim.inspect(event.properties.part.text))
        -- put this event in the earlier slot

        -- move this newer part to the position of the original part
        collapsed_events[part_update_indices[part_id]] = event

        -- clear out this parts now unneeded position
        collapsed_events[i] = nil
      else
        part_update_indices[part_id] = i
        collapsed_events[i] = event
      end
    else
      collapsed_events[i] = event
    end
  end

  local actually_emitted = 0

  for i = 1, #events do
    local event = collapsed_events[i]
    if event then
      actually_emitted = actually_emitted + 1
      self:emit(event.type, event.properties)
    end
  end

  if config.debug.enabled then
    vim.notify('Drained ' .. #events .. ', actually emitted: ' .. actually_emitted)
  end

  self:emit('custom.emit_events.finished', {})
end

--- Emit an event to all subscribers
--- @param event_name OpencodeEventName The event name
--- @param data any Data to pass to event listeners
function EventManager:emit(event_name, data)
  local listeners = self.events[event_name]
  if not listeners then
    return
  end

  local event = { type = event_name, properties = data }

  if require('opencode.config').debug.capture_streamed_events then
    table.insert(self.captured_events, vim.deepcopy(event))
  end

  for _, callback in ipairs(listeners) do
    pcall(callback, data)
  end
end

--- Start the event manager and begin listening to server events
function EventManager:start()
  if self.is_started then
    return
  end

  self.is_started = true

  state.subscribe(
    'opencode_server',
    --- @param key string
    --- @param current OpencodeServer|nil
    --- @param prev OpencodeServer|nil
    function(key, current, prev)
      if current and current:get_spawn_promise() then
        self:emit('custom.server_starting', { server_job = current })

        current:get_spawn_promise():and_then(function(server)
          self:emit('custom.server_ready', { server_job = server, url = server.url })
          vim.defer_fn(function()
            self:_subscribe_to_server_events(server)
          end, 200)
        end)

        current:get_shutdown_promise():and_then(function()
          self:emit('custom.server_stopped', {})
          self:_cleanup_server_subscription()
        end)
      elseif prev and not current then
        self:emit('custom.server_stopped', {})
        self:_cleanup_server_subscription()
      end
    end
  )
end

function EventManager:stop()
  if not self.is_started then
    return
  end

  self.is_started = false
  self:_cleanup_server_subscription()

  self.throttling_emitter:clear()
  self.events = {}
end

--- Subscribe to server-sent events from the API
--- @param server table The server instance
function EventManager:_subscribe_to_server_events(server)
  if not server.url then
    return
  end

  self:_cleanup_server_subscription()

  local api_client = state.api_client

  local emitter = function(event)
    self.throttling_emitter:enqueue(event)
  end

  self.server_subscription = api_client:subscribe_to_events(nil, emitter)
end

function EventManager:_cleanup_server_subscription()
  if self.server_subscription then
    pcall(function()
      if self.server_subscription.shutdown then
        self.server_subscription:shutdown()
      elseif self.server_subscription.pid and type(self.server_subscription.pid) == 'number' then
        vim.fn.jobstop(self.server_subscription.pid)
      end
    end)
    self.server_subscription = nil
  end
end

--- Get all event names that have subscribers
--- @return string[] List of event names
function EventManager:get_event_names()
  local names = {}
  for name, _ in pairs(self.events) do
    table.insert(names, name)
  end
  return names
end

--- Get number of subscribers for an event
--- @param event_name OpencodeEventName The event name
--- @return number Number of subscribers
function EventManager:get_subscriber_count(event_name)
  local listeners = self.events[event_name]
  return listeners and #listeners or 0
end

function EventManager.setup()
  state.event_manager = EventManager.new()
  state.event_manager:start()
end

return EventManager
