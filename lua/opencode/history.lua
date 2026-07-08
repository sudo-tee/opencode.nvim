local state = require('opencode.state')
local input_window = require('opencode.ui.input_window')

---@class OpencodeHistoryEntry
---@field id string Message ID from the server
---@field message OpencodeMessage Full message; lets callers rebuild the prompt
---@field prompt { lines: string[], mention_paths: string[] } Reconstructed prompt

local M = {}

M.index = nil

-- Track which session the current ring index is bound to so navigating
-- across sessions always restarts from the newest entry.
local cached_session_id = nil

-- The user's draft at the time they first navigate backwards through history.
-- Restored when they navigate past the newest entry again.
local prompt_before_history = nil

local function active_session_id()
  return state.active_session and state.active_session.id
end

local function maybe_reset_for_new_session()
  local session_id = active_session_id()
  if session_id ~= cached_session_id then
    M.index = nil
    prompt_before_history = nil
    cached_session_id = session_id
  end
end

---@param entry OpencodeHistoryEntry
local function entry_has_content(entry)
  local prompt = entry.prompt
  if not prompt then
    return false
  end
  if prompt.mention_paths and #prompt.mention_paths > 0 then
    return true
  end
  local lines = prompt.lines
  if not lines or #lines == 0 then
    return false
  end
  if #lines > 1 then
    return true
  end
  return lines[1] ~= nil and lines[1] ~= ''
end

--- Read user-message prompt history for the active session, newest first.
--- Pure read against `state.messages`; if no entry has been populated yet
--- (e.g. right after switching sessions before SSE catches up) the result is
--- an empty list. Populating `state.messages` is the renderer's job.
---@return OpencodeHistoryEntry[]
function M.read()
  maybe_reset_for_new_session()
  local active_id = active_session_id()
  if not active_id then
    return {}
  end
  local messages = state.messages or {}
  local collected = {}
  for _, msg in ipairs(messages) do
    if msg.info and msg.info.role == 'user' and msg.info.sessionID == active_id then
      local prompt = input_window.build_prompt_from_message(msg)
      if prompt then
        local entry = { id = msg.info.id, message = msg, prompt = prompt } ---@type OpencodeHistoryEntry
        if entry_has_content(entry) then
          table.insert(collected, entry)
        end
      end
    end
  end

  -- Reverse so the newest user message is at index 1; prev() walks 1 -> N.
  local reversed = {}
  for i = 1, #collected do
    reversed[i] = collected[#collected - i + 1]
  end
  return reversed
end

--- Walk one step backwards through history. The first call captures the
--- current input draft so the next forward navigation can restore it.
---@return OpencodeHistoryEntry?
function M.prev()
  local entries = M.read()
  if #entries == 0 then
    return nil
  end

  if not M.index or M.index == 0 then
    prompt_before_history = state.input_content
  end

  M.index = (M.index or 0) + 1
  if M.index > #entries then
    M.index = #entries
  end

  return entries[M.index]
end

--- Walk one step forwards through history.
---
--- Returns one of three shapes depending on where we are in the ring:
---   * `OpencodeHistoryEntry` while still walking through user messages
---   * `string[]` once we cross past the newest entry; this is the
---     pre-history draft captured on the first `prev()` call
---   * `nil` when no history navigation is in progress
---@return (OpencodeHistoryEntry|string[])?
function M.next()
  if not M.index then
    return nil
  end
  local entries = M.read()
  if M.index <= 1 then
    M.index = nil
    return prompt_before_history
  end

  M.index = M.index - 1
  return entries[M.index]
end

--- Forget the navigation cursor. Call this when the user sends a new prompt
--- or the active session changes.
function M.reset()
  M.index = nil
  prompt_before_history = nil
end

-- Reset on session changes too. Subscribers react synchronously, so the next
-- read() call sees the new active_session and clears state via
-- maybe_reset_for_new_session.
state.store.subscribe('active_session', function(_, new_session)
  if new_session and new_session.id ~= cached_session_id then
    M.reset()
  end
end)

return M
