local lifecycle = require('opencode.protocols.observation')
local messages = require('opencode.protocols.v2.observation.messages')
local resources = require('opencode.protocols.v2.observation.resources')
local events = require('opencode.protocols.v2.observation.events')
local actions = require('opencode.protocols.v2.observation.actions')

local M = {
  ingest_snapshot = messages.ingest_snapshot,
  ingest_event = messages.ingest_event,
}

---@param connection OpencodeV2Connection
---@param ref OpencodeV2SessionRef
---@return OpencodeV2Observation
function M.new(connection, ref)
  local session = { id = ref.id }
  if ref.location ~= nil then
    session.location = vim.deepcopy(ref.location)
  end

  local observation = lifecycle.attach(connection, session, lifecycle.new_state(session), {
    name = 'V2',
    find_reply = messages.find_reply,
    ---@param resource OpencodeObservedResource
    ---@return boolean
    local_resource = function(resource)
      return resource == 'files'
    end,
    ---@param resource OpencodeObservedResource
    ---@param sync table
    ---@return boolean
    refresh_after_event = function(resource, sync)
      return resource ~= 'files' and sync.state == 'error'
    end,
    request_resource = resources.request,
    apply_resource = resources.apply,
    route_event = events.route,
    ---@param current OpencodeObservation
    ---@param resource OpencodeObservedResource
    on_release_resource = function(current, resource)
      ---@cast current OpencodeV2Observation
      if resource == 'messages' then
        messages.release(current)
      end
    end,
    on_stream_error = actions.invalidate_submissions,
    ---@param current OpencodeObservation
    on_close = function(current)
      ---@cast current OpencodeV2Observation
      actions.invalidate_submissions(current, 'connection closed')
    end,
  })
  ---@cast observation OpencodeV2Observation

  messages.initialize(observation)
  events.initialize(observation)
  messages.attach_history(observation, connection)
  actions.attach(observation, connection)
  return observation
end

---@param connection OpencodeV2Connection
function M.close(connection)
  lifecycle.close(connection)
end

return M
