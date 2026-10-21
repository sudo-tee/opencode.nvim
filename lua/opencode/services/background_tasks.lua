-- Counts background jobs that are still running in an observation's loaded entries.
local M = {}

---@class OpencodeBackgroundTaskCounts
---@field shells integer Background shells still running
---@field subagents integer Background subagents still running
---@field total integer Sum of shells and subagents

---@return OpencodeBackgroundTaskCounts
local function empty_counts()
  return { shells = 0, subagents = 0, total = 0 }
end

---@param entries table[]
---@return OpencodeBackgroundTaskCounts
function M.count(entries)
  local completed = {}
  for _, entry in ipairs(entries) do
    local result = entry.background_result
    if result then
      completed[result.id] = true
    end
  end

  local counts = empty_counts()
  local seen = {}
  for _, entry in ipairs(entries) do
    for _, part in ipairs(entry.content) do
      local background = part.background
      local id = background and background.id
      if id and not completed[id] and not seen[id] then
        seen[id] = true
        if part.name == 'shell' or part.name == 'bash' then
          counts.shells = counts.shells + 1
        else
          counts.subagents = counts.subagents + 1
        end
      end
    end
  end

  counts.total = counts.shells + counts.subagents
  return counts
end

---@param observation OpencodeObservation|nil
---@return OpencodeBackgroundTaskCounts
function M.count_observed(observation)
  if not observation then
    return empty_counts()
  end

  local observed = observation:read()
  local entries = {}
  for _, id in ipairs(observed.entry_order) do
    local entry = observed.entries_by_id[id]
    if entry then
      entries[#entries + 1] = entry
    end
  end
  return M.count(entries)
end

return M
