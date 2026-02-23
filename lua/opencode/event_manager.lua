local state = require('opencode.state')
local config = require('opencode.config')
local ThrottlingEmitter = require('opencode.throttling_emitter')
local util = require('opencode.util')
local log = require('opencode.log')

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

--- @class EventMessagePartDelta
--- @field type "message.part.delta"
--- @field properties {
---   sessionID: string,
---   messageID: string,
---   partID: string,
---   field: string,
---   delta: string
--- }

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
--- @field tool? {messageID: string, callID: string}
--- @field messageID string
--- @field callID? string
--- @field title string
--- @field metadata table
--- @field time {created: number}

--- @class OpencodePermissionAsked
--- @field id string
--- @field type string
--- @field pattern string|string[]
--- @field sessionID string
--- @field tool? {messageID: string, callID: string}
--- @field messageID string
--- @field callID? string
--- @field title string
--- @field metadata table
--- @field time {created: number}

--- @class EventPermissionUpdated
--- @field type "permission.updated"
--- @field properties OpencodePermission

--- @class EventPermissionAsked
--- @field type "permission.asked"
--- @field properties OpencodePermission

--- @class EventPermissionReplied
--- @field type "permission.replied"
--- @field properties {sessionID: string, permissionID?: string, requestID?: string, response: string}

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
--- @field url string

--- @class ServerReadyEvent
--- @field url string

--- @class ServerStoppedEvent

--- @class RestorePointCreatedEvent
--- @field restore_point RestorePoint

--- @class EventQuestionAsked
--- @field type "question.asked"
--- @field properties OpencodeQuestionRequest

--- @class EventQuestionReplied
--- @field type "question.replied"
--- @field properties { sessionID: string, requestID: string, answers: string[][] }

--- @class EventQuestionRejected
--- @field type "question.rejected"
--- @field properties { sessionID: string, requestID: string }

--- @alias OpencodeEventName
--- | "installation.updated"
--- | "lsp.client.diagnostics"
--- | "message.updated"
--- | "message.removed"
--- | "message.part.updated"
--- | "message.part.delta"
--- | "message.part.removed"
--- | "session.compacted"
--- | "session.idle"
--- | "session.updated"
--- | "session.deleted"
--- | "session.error"
--- | "permission.updated"
--- | "permission.asked"
--- | "permission.replied"
--- | "question.asked"
--- | "question.replied"
--- | "question.rejected"
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
--- @field state_server_listener function|nil Listener for state.opencode_server updates
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
    state_server_listener = nil,
    is_started = false,
    captured_events = {},
    _parts_by_id = {},
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
--- @overload fun(self: EventManager, event_name: "message.part.delta", callback: fun(data: EventMessagePartDelta['properties']): nil)
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

  for _, cb in ipairs(self.events[event_name]) do
    if cb == callback then
      return
    end
  end

  table.insert(self.events[event_name], callback)
end

--- Unsubscribe from an event with type-safe callbacks using function overloads
--- @overload fun(self: EventManager, event_name: "installation.updated", callback: fun(data: EventInstallationUpdated['properties']): nil)
--- @overload fun(self: EventManager, event_name: "lsp.client.diagnostics", callback: fun(data: EventLspClientDiagnostics['properties']): nil)
--- @overload fun(self: EventManager, event_name: "message.updated", callback: fun(data: EventMessageUpdated['properties']): nil)
--- @overload fun(self: EventManager, event_name: "message.removed", callback: fun(data: EventMessageRemoved['properties']): nil)
--- @overload fun(self: EventManager, event_name: "message.part.updated", callback: fun(data: EventMessagePartUpdated['properties']): nil)
--- @overload fun(self: EventManager, event_name: "message.part.delta", callback: fun(data: EventMessagePartDelta['properties']): nil)
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

  for i = #listeners, 1, -1 do
    local cb = listeners[i]
    if cb == callback then
      table.remove(listeners, i)
    end
  end
end

---Normalize message.part.delta events into message.part.updated events so
---consumers can continue rendering full part payloads.
---@param event table
---@return table|nil
function EventManager:_normalize_stream_event(event)
  if not event or not event.type then
    return nil
  end

  local properties = event.properties or {}

  if event.type == 'message.part.updated' and properties.part and properties.part.id then
    self._parts_by_id[properties.part.id] = vim.deepcopy(properties.part)
    return event
  end

  if event.type == 'message.part.removed' and properties.partID then
    self._parts_by_id[properties.partID] = nil
    return event
  end

  if event.type ~= 'message.part.delta' then
    return event
  end

  local part_id = properties.partID
  local message_id = properties.messageID
  local session_id = properties.sessionID
  local field = properties.field

  if not part_id or not message_id or not session_id or not field then
    return nil
  end

  local part = vim.deepcopy(self._parts_by_id[part_id])
  if not part then
    part = {
      id = part_id,
      messageID = message_id,
      sessionID = session_id,
    }

    if field == 'text' then
      part.type = 'text'
      part.text = ''
    end
  end

  local delta = properties.delta
  local current = part[field]
  if type(delta) == 'string' then
    if type(current) == 'string' then
      part[field] = current .. delta
    else
      part[field] = delta
    end
  else
    part[field] = delta
  end

  self._parts_by_id[part_id] = part

  return {
    type = 'message.part.updated',
    properties = {
      part = part,
    },
  }
end

---Callback from ThrottlingEmitter when the events are now ready to be processed.
---Collapses parts that are duplicated, making sure to replace earlier parts with later
---ones (but keeping the earlier position)
---@param events any
function EventManager:_on_drained_events(events)
  self:emit('custom.emit_events.started', {})

  local normalized_events = {}
  for _, event in ipairs(events) do
    local normalized_event = self:_normalize_stream_event(event)
    if normalized_event then
      table.insert(normalized_events, normalized_event)
    end
  end

  if not config.ui.output.rendering.event_collapsing then
    for _, event in ipairs(normalized_events) do
      if event and event.type then
        self:emit(event.type, event.properties)
      else
        log.warn('Received event with missing type: %s', vim.inspect(event))
      end
    end
    self:emit('custom.emit_events.finished', {})
    return
  end

  local collapsed_events = {}
  local part_update_indices = {}

  for i, event in ipairs(normalized_events) do
    if event.type == 'message.part.updated' and event.properties.part then
      local part_id = event.properties.part.id
      if part_update_indices[part_id] then
        local previous_index = part_update_indices[part_id]

        -- Preserve ordering dependencies for permission events.
        -- Moving a later part update earlier can break correlation when
        -- permission.updated/permission.asked sits between the two updates.
        local has_intervening_permission_event = false
        for j = previous_index + 1, i - 1 do
          if
            normalized_events[j]
            and (normalized_events[j].type == 'permission.updated' or normalized_events[j].type == 'permission.asked')
          then
            has_intervening_permission_event = true
            break
          end
        end

        if has_intervening_permission_event then
          collapsed_events[previous_index] = nil
          collapsed_events[i] = event
          part_update_indices[part_id] = i
        else
          collapsed_events[previous_index] = event
          collapsed_events[i] = nil
        end
      else
        part_update_indices[part_id] = i
        collapsed_events[i] = event
      end
    else
      collapsed_events[i] = event
    end
  end

  for i = 1, #normalized_events do
    local event = collapsed_events[i]
    if event and event.type then
      self:emit(event.type, event.properties)
    elseif event then
      log.warn('Received collapsed event with missing type: %s', vim.inspect(event))
    end
  end

  self:emit('custom.emit_events.finished', {})
end

--- Emit an event to all subscribers
--- @param event_name OpencodeEventName The event name
--- @param data table Data to pass to event listeners
function EventManager:emit(event_name, data)
  local listeners = self.events[event_name]

  local event = { type = event_name, properties = data }

  if config.debug.capture_streamed_events then
    table.insert(self.captured_events, vim.deepcopy(event))
  end

  if listeners then
    for _, callback in ipairs(listeners) do
      local ok, result = util.pcall_trace(callback, data)

      if not ok then
        vim.notify('Error calling ' .. event_name .. ' listener: ' .. result, vim.log.levels.ERROR)
      end
    end
  end

  vim.api.nvim_exec_autocmds('User', {
    pattern = 'OpencodeEvent:' .. event_name,
    data = {
      event = event,
    },
  })
end

--- Start the event manager and begin listening to server events
function EventManager:start()
  if self.is_started then
    return
  end

  self.is_started = true

  if self.state_server_listener then
    state.unsubscribe('opencode_server', self.state_server_listener)
  end

  self.state_server_listener = function(key, current, prev)
    if current and current:get_spawn_promise() then
      self:emit('custom.server_starting', { url = current.url })

      current:get_spawn_promise():and_then(function(server)
        self:emit('custom.server_ready', { url = server.url })
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

  state.subscribe('opencode_server', self.state_server_listener)
end

function EventManager:stop()
  if not self.is_started then
    return
  end

  self.is_started = false
  if self.state_server_listener then
    state.unsubscribe('opencode_server', self.state_server_listener)
    self.state_server_listener = nil
  end
  self:_cleanup_server_subscription()

  self.throttling_emitter:clear()
  self._parts_by_id = {}
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
        vim.fn.jobstop(self.server_subscription.pid --[[@as integer]])
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
