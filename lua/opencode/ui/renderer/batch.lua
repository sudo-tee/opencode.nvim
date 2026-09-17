local M = {}

---Collects resource changes per key and applies them once, on the deadline set by
---the change that opened the batch; later changes join it without moving that
---deadline. A batch belongs to the display context that opened it, so a context
---replaced before the deadline drops the accumulated work instead of applying it.
---@class OpencodeRendererBatchOptions
---@field context fun(): integer, table|nil Current display generation and observation
---@field schedule fun(callback: fun(), delay?: number)
---@field apply fun(resources: table<table, table<string, boolean>>)
---@field on_pending? fun(pending: boolean) Called when a batch opens and when it settles

---@class OpencodeRendererBatch
---@field drain fun(self: OpencodeRendererBatch) Apply the open batch now
---@field discard fun(self: OpencodeRendererBatch, key: table) Drop one key's queued resources
---@field cancel fun(self: OpencodeRendererBatch) Drop the open batch entirely
---@field enqueue fun(self: OpencodeRendererBatch, key: table, resource: string, delay?: number)

---@param options OpencodeRendererBatchOptions
---@return OpencodeRendererBatch
function M.new(options)
  ---@type {generation: integer, observation: table|nil, resources: table}|nil
  local active
  local batch = {}

  local function set_pending(pending)
    if options.on_pending then
      options.on_pending(pending)
    end
  end

  local function same_context(token)
    local generation, observation = options.context()
    return token.generation == generation and token.observation == observation
  end

  function batch:drain()
    local token = active
    if not token then
      return
    end
    active = nil
    if not same_context(token) then
      return
    end
    set_pending(false)
    options.apply(token.resources)
  end

  function batch:discard(key)
    if active then
      active.resources[key] = nil
    end
  end

  function batch:cancel()
    active = nil
    set_pending(false)
  end

  function batch:enqueue(key, resource, delay)
    local starting_batch = not active or not same_context(active)
    if starting_batch then
      local generation, observation = options.context()
      active = { generation = generation, observation = observation, resources = {} }
    end
    local resources = active.resources[key] or {}
    resources[resource] = true
    active.resources[key] = resources
    if not starting_batch then
      return
    end
    set_pending(true)
    local token = active
    options.schedule(function()
      if active == token then
        self:drain()
      end
    end, delay)
  end

  return batch
end

return M
