local Promise = require('opencode.promise')

local M = {}

local function find_reply(observation, input_id, protocol)
  local state = observation:read()
  local input_found = false
  local reply
  for _, id in ipairs(state.entry_order) do
    local entry = state.entries_by_id[id]
    if protocol == 'v1' then
      if entry.parent_message_id == input_id and (entry.finish == 'stop' or entry.error) then
        return entry
      end
    elseif entry.kind == 'user' then
      if input_found or entry.id ~= input_id then
        return nil
      end
      input_found = true
    elseif entry.kind == 'assistant' then
      if not input_found then
        return nil
      end
      reply = entry
    end
  end
  return input_found and reply or nil
end

---@class OpencodeReplyRequest
---@field promise table Resolves to an assistant message; the caller validates its content
---@field stop fun(reason?: string)

---Submit one input to a fresh, exclusively owned session and await its reply.
---@param observation table
---@param input table
---@param protocol string
---@return OpencodeReplyRequest
function M.start(observation, input, protocol)
  local reply = Promise.new()
  local input_id
  local unsubscribe = observation:watch({ 'messages' }, function()
    if input_id and protocol == 'v1' then
      local message = find_reply(observation, input_id, protocol)
      if message then
        reply:resolve(message)
      end
    end
  end)
  local function stop(reason)
    if unsubscribe then
      unsubscribe()
      unsubscribe = nil
    end
    if reason then
      reply:reject(reason)
    end
  end
  Promise.async(function()
    local result = observation:submit(input):await()
    if reply:is_resolved() then
      return
    end
    if result.kind == 'reply' then
      reply:resolve(result.message)
      return
    end
    input_id = result.input.id
    if protocol ~= 'v1' then
      local completion = observation:wait_until_idle():await()
      if completion.outcome ~= 'succeeded' then
        error('Reply request completion failed: ' .. vim.inspect(completion))
      end
    end
    local message = find_reply(observation, input_id, protocol)
    if message then
      reply:resolve(message)
    elseif protocol ~= 'v1' then
      error('Reply request cannot associate the completed reply with its input')
    end
  end)():catch(function(err)
    reply:reject(err)
  end)
  return { promise = reply:finally(function() stop() end), stop = stop }
end

return M
