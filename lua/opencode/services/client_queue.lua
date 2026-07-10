local state = require('opencode.state')
local loading_animation = require('opencode.ui.loading_animation')
local messaging = require('opencode.services.messaging')

local M = {}

---@class OpencodeClientQueueItem
---@field prompt string
---@field opts? SendMessageOpts
---@field enqueued_at integer

---@type OpencodeClientQueueItem[]
local _queue = {}

local tool_call_is_running = {}

local _setup_done = false

---@return string|nil
local function current_session_id()
  local s = state.active_session
  return s and s.id or nil
end

---@param session_id string
---@return boolean
local function is_session_idle(session_id)
  local status = loading_animation.get_status(session_id)
  return not status or status.type == 'idle'
end

local function refresh_hint()
  local ok, input_window = pcall(require, 'opencode.ui.input_window')
  if not ok or not input_window or not input_window.render_queue_hint then
    return
  end
  input_window.render_queue_hint(#_queue)
end

---Drain one item from the queue, but only when the active session is
---idle. Returns true if an item was drained.
---@return boolean drained_one
function M.flush_one_if_idle()
  if #_queue == 0 then
    return false
  end
  local sid = current_session_id()
  if not sid then
    return false
  end
  local messages = state.messages or {}
  if not is_session_idle(sid) and not tool_call_is_running[sid] then
    return false
  end
  local item = table.remove(_queue, 1)
  refresh_hint()
  messaging.send_message(item.prompt, item.opts or {})
  return true
end

---Drain one item unconditionally (no status check). Used by the tool-call
---completion listener, which knows the server's runLoop is about to read
---store for the next step.
---@return boolean drained_one
function M.flush_one_now()
  if #_queue == 0 then
    return false
  end
  local sid = current_session_id()
  if not sid then
    return false
  end
  local item = table.remove(_queue, 1)
  refresh_hint()
  messaging.send_message(item.prompt, item.opts or {})
  return true
end

---Submit a prompt to the active session.
---Drains immediately if the session is idle; otherwise holds in queue and
---lets the tool-call completion listener pick it up.
---@param prompt string
---@param opts? SendMessageOpts
function M.submit(prompt, opts)
  if not prompt or prompt == '' then
    return
  end
  M.setup()
  table.insert(_queue, {
    prompt = prompt,
    opts = opts,
    enqueued_at = os.time(),
  })
  refresh_hint()
  while M.flush_one_if_idle() do
  end
end

---@return integer
function M.size()
  return #_queue
end

---@return OpencodeClientQueueItem|nil
function M.undo_last()
  if #_queue == 0 then
    return nil
  end
  local item = table.remove(_queue)
  refresh_hint()
  return item
end

function M.clear()
  _queue = {}
  refresh_hint()
end

---@param properties EventMessagePartUpdated['properties']
local function on_part_updated(properties)
  local part = properties.part
  local sid = current_session_id()
  if not sid or part.sessionID and part.sessionID ~= sid or part.type ~= 'tool' then
    return
  end
  if part.state.status == 'completed' then
    tool_call_is_running[sid] = nil
    return
  end
  tool_call_is_running[sid] = true
  while M.flush_one_now() do
  end
end

function M.setup()
  if _setup_done then
    return
  end
  _setup_done = true
  local mgr = state.event_manager
  if not mgr or type(mgr.subscribe) ~= 'function' then
    return
  end
  mgr:subscribe('message.part.updated', on_part_updated)
end

return M
