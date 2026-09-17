local batch = require('opencode.ui.renderer.batch')
local ctx = require('opencode.ui.renderer.ctx')
local config = require('opencode.config')
local state = require('opencode.state')

local M = {}

---@class OpencodeRenderSession
---@field attach fun(self: OpencodeRenderSession)
---@field drain fun(self: OpencodeRenderSession)
---@field close fun(self: OpencodeRenderSession)
---@field child fun(self: OpencodeRenderSession, session_id: string): table|nil
---@field child_id fun(self: OpencodeRenderSession, observation: table): string|nil
---@field sync_children fun(self: OpencodeRenderSession): table[]

---A resource that has only started loading carries no new state to display. An
---observation that does not track the resource at all reports no sync state for it.
local function is_loading(observation, resource)
  local sync = observation:read().sync[resource]
  return sync ~= nil and sync.state == 'loading'
end

---Only root message streaming is collapsed, and only once something is on screen:
---every other change reconciles on the next event loop turn.
local function stream_throttle_ms(resource)
  if resource ~= 'messages' or not next(ctx.render_state._messages) then
    return 0
  end
  local rendering = config.ui.output.rendering
  return rendering.event_collapsing ~= false and rendering.event_throttle_ms or 0
end

---Own live subscriptions and batches independently of the saved display caches.
---@param root table
---@param reconcile fun(observation: table, resources: table<string, boolean>)
---@return OpencodeRenderSession
function M.new(root, reconcile)
  local session = {}
  ---@type table<string, {observation: table, unsubscribe: fun()}>
  local child_by_id = {}
  ---@type table<table, string>
  local id_by_observation = {}
  ---Last children snapshot proven current, per observed session id, root included.
  ---@type table<string, table[]>
  local child_refs_by_id = {}
  local unsubscribe_root
  local closed = false

  local function context()
    return ctx.generation, ctx.observation
  end

  local root_batch = batch.new({
    context = context,
    on_pending = function(pending)
      ctx.reconcile_scheduled = pending
    end,
    schedule = function(callback, delay)
      if delay > 0 then
        vim.defer_fn(callback, delay)
      else
        vim.schedule(callback)
      end
    end,
    apply = function(changed)
      reconcile(root, changed[root])
    end,
  })

  local child_batch = batch.new({
    context = context,
    schedule = function(callback)
      vim.schedule(callback)
    end,
    apply = function(changed)
      for child, resources in pairs(changed) do
        if id_by_observation[child] then
          reconcile(child, resources)
        end
      end
    end,
  })

  function session:attach()
    if closed or unsubscribe_root then
      return
    end
    unsubscribe_root = root:watch(
      { 'session', 'messages', 'children', 'execution', 'permissions', 'questions', 'inbox', 'files' },
      function(_, resource)
        if not closed and not is_loading(root, resource) then
          root_batch:enqueue(root, resource, stream_throttle_ms(resource))
        end
      end
    )
  end

  local function observe_child(ref)
    local connection = state.opencode_server
    if not connection or not connection:is_ready() then
      error('cannot observe child sessions without a ready Connection')
    end
    local child = connection:observe(ref)
    local record = { observation = child }
    child_by_id[ref.id], id_by_observation[child] = record, ref.id
    record.unsubscribe = child:watch(
      { 'messages', 'children', 'permissions', 'questions' },
      function(observation, resource)
        if not closed and id_by_observation[observation] and not is_loading(observation, resource) then
          child_batch:enqueue(observation, resource)
        end
      end
    )
    return child
  end

  function session:child(session_id)
    local record = child_by_id[session_id]
    return record and record.observation
  end

  function session:child_id(observation)
    return id_by_observation[observation]
  end

  function session:sync_children()
    local root_id = root:read().session.id
    local observations = { root }
    local seen = { [root_id] = true }
    local queue = { { id = root_id, observation = root } }
    local cursor = 1
    while cursor <= #queue do
      local node = queue[cursor]
      cursor = cursor + 1
      local observed = node.observation:read()
      -- A loading or failed snapshot cannot prove that a known child disappeared,
      -- so the last current snapshot stays authoritative until a newer one arrives.
      local children_sync = observed.sync.children
      if children_sync and children_sync.state == 'current' then
        local refs = {}
        for _, child_id in ipairs(observed.children.order or {}) do
          local ref = observed.children.by_id[child_id]
          if ref then
            refs[#refs + 1] = ref
          end
        end
        child_refs_by_id[node.id] = refs
      end
      for _, ref in ipairs(child_refs_by_id[node.id] or {}) do
        if not seen[ref.id] then
          seen[ref.id] = true
          local child = self:child(ref.id) or observe_child(ref)
          observations[#observations + 1] = child
          queue[#queue + 1] = { id = ref.id, observation = child }
        end
      end
    end

    for id, record in pairs(child_by_id) do
      if not seen[id] then
        id_by_observation[record.observation] = nil
        child_batch:discard(record.observation)
        record.unsubscribe()
        child_by_id[id], child_refs_by_id[id] = nil, nil
      end
    end
    return observations
  end

  function session:drain()
    root_batch:drain()
    child_batch:drain()
  end

  function session:close()
    if closed then
      return
    end
    closed = true
    root_batch:cancel()
    child_batch:cancel()
    for _, record in pairs(child_by_id) do
      record.unsubscribe()
    end
    child_by_id, id_by_observation, child_refs_by_id = {}, {}, {}
    if unsubscribe_root then
      unsubscribe_root()
      unsubscribe_root = nil
    end
  end

  return session
end

return M
