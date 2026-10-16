local store = require('opencode.state.store')

local M = {}
local next_id = 0

---@class OpencodeOptimisticPrompt
---@field id string
---@field server_id? string
---@field session_id string
---@field text string
---@field created number
---@field status 'sending'|'failed'|'unknown'

---@type table<OpencodeObservation, OpencodeOptimisticPrompt[]|nil>
local prompts = setmetatable({}, { __mode = 'k' })

local function changed()
  store.update('optimistic_revision', function(value)
    return value + 1
  end)
end

---Local display state only; never inserts entries into authoritative history.
---@param observation OpencodeObservation
---@param text string
---@return OpencodeOptimisticPrompt
function M.begin(observation, text)
  next_id = next_id + 1
  ---@type OpencodeOptimisticPrompt
  local prompt = {
    id = '__opencode_pending_' .. next_id,
    session_id = observation:read().session.id,
    text = text,
    created = os.time() * 1000,
    status = 'sending',
  }
  prompts[observation] = prompts[observation] or {}
  table.insert(prompts[observation], prompt)
  changed()
  return prompt
end

---@param prompt OpencodeOptimisticPrompt
---@param id string
function M.bind(prompt, id)
  prompt.server_id = id
  changed()
end

---@param observation OpencodeObservation
---@param prompt OpencodeOptimisticPrompt
---@param failure? 'failed'|'unknown'
function M.finish(observation, prompt, failure)
  if failure then
    prompt.status = failure
  else
    local pending = prompts[observation] or {}
    for index, candidate in ipairs(pending) do
      if candidate == prompt then
        table.remove(pending, index)
        break
      end
    end
  end
  changed()
end

---@param observation OpencodeObservation
---@return OpencodeOptimisticPrompt[]
local function visible(observation)
  local result = {}
  local entries = observation:read().entries_by_id
  for _, prompt in ipairs(prompts[observation] or {}) do
    if not (prompt.server_id and entries[prompt.server_id]) then
      result[#result + 1] = prompt
    end
  end
  return result
end

---@param observation OpencodeObservation
---@return boolean
function M.is_sending(observation)
  for _, prompt in ipairs(visible(observation)) do
    if prompt.status == 'sending' then
      return true
    end
  end
  return false
end

---@param observation OpencodeObservation
---@param entries table[]
---@return table[]
function M.project(observation, entries)
  local result = vim.list_extend({}, entries)
  for _, prompt in ipairs(visible(observation)) do
    result[#result + 1] = {
      id = prompt.id,
      session_id = prompt.session_id,
      kind = 'user',
      local_status = prompt.status,
      time = { created = prompt.created },
      content = { { kind = 'text', text = prompt.text } },
    }
  end
  return result
end

return M
