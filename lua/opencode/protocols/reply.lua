local Promise = require('opencode.promise')

local M = {}

---@class OpencodeReplyRequest
---@field promise Promise Resolves to an assistant message; the caller validates its content
---@field stop fun(reason?: string)

---Submit one input to a fresh, exclusively owned session and await its reply.
---@param observation table
---@param input table
---@return OpencodeReplyRequest
function M.start(observation, input)
  local reply = Promise.new()
  local submitted
  local stopped
  local unsubscribe = observation:watch({ 'messages' }, function() end)
  local function cleanup()
    if unsubscribe then
      unsubscribe()
      unsubscribe = nil
    end
  end
  local function stop(reason)
    stopped = reason or 'Reply request cancelled'
    if submitted then
      submitted.stop(stopped)
    end
    reply:reject(stopped)
    cleanup()
  end
  Promise.async(function()
    submitted = observation:submit(input):await()
    if stopped then
      submitted.stop(stopped)
      return
    end
    local completion = submitted.completion:await()
    if reply:is_resolved() then
      return
    end
    if completion.kind == 'reply' then
      reply:resolve(completion.message)
      return
    end
    if completion.outcome ~= 'succeeded' then
      error('Reply request completion failed: ' .. vim.inspect(completion))
    end
    local message = observation._runtime.find_reply(observation, submitted.input.id)
    if not message then
      error('Reply request cannot associate the completed reply with its input')
    end
    reply:resolve(message)
  end)():catch(function(err)
    reply:reject(err)
  end)
  return { promise = reply:finally(cleanup), stop = stop }
end

return M
