local Promise = require('opencode.promise')

local M = {}

---@class OpencodeReplyCompletion
---@field kind 'reply'
---@field input_id string
---@field message table

---@class OpencodeIdleCompletion
---@field kind 'session_idle'
---@field outcome 'succeeded'|'failed'|'interrupted'
---@field idle_at number
---@field error? table

---@alias OpencodeSubmissionCompletion OpencodeReplyCompletion|OpencodeIdleCompletion

---@class OpencodeSubmission
---@field kind 'reply'|'accepted'
---@field input? table Accepted input, including its protocol-owned ID
---@field input_id? string Input ID for an immediate reply
---@field message? table Immediate assistant reply
---@field completion Promise<OpencodeSubmissionCompletion>
---@field stop fun(reason?: string) Cancel local waiting without interrupting the server

---@param result table
---@param cleanup? fun()
---@return OpencodeSubmission
---@return fun(value?: table, err?: any) finish
function M.new(result, cleanup)
  local completion = Promise.new()
  local function finish(value, err)
    if completion:is_resolved() then
      return
    end
    if err ~= nil then
      completion:reject(err)
    else
      completion:resolve(value)
    end
    if cleanup then
      cleanup()
    end
  end
  result.completion = completion
  result.stop = function(reason)
    finish(nil, reason or 'Submission cancelled')
  end
  return result, finish
end

return M
