local lifecycle = require('opencode.protocols.observation')

local M = {}

---@param message string
function M.fail(message)
  error('V2 observation: ' .. message, 0)
end

---@param observation OpencodeV2Observation
---@param resource OpencodeObservedResource
---@param message string
---@return false
function M.diagnostic(observation, resource, message)
  observation:read().sync[resource] = lifecycle.sync_error('protocol_contract', message)
  return false
end

---@param event any
---@return boolean
function M.valid_event(event)
  if type(event) ~= 'table' or type(event.type) ~= 'string' or type(event.data) ~= 'table' then
    return false
  end
  return type(event.created) == 'number'
end

return M
