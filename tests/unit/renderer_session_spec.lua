local RenderSession = require('opencode.ui.renderer.session')
local ctx = require('opencode.ui.renderer.ctx')
local state = require('opencode.state')
local config = require('opencode.config')
local stub = require('luassert.stub')

describe('renderer session ownership', function()
  local sessions, observations, callbacks, scheduled, applied
  local schedule_stub, defer_stub, old_server, old_observation, old_throttle, old_collapsing

  local function observation(id, child_ids)
    local observed = {
      session = { id = id },
      sync = { children = { state = 'current' } },
      children = { order = child_ids or {}, by_id = {} },
    }
    for _, child_id in ipairs(child_ids or {}) do
      observed.children.by_id[child_id] = { id = child_id }
    end
    local current = { subscriptions = 0, releases = 0 }
    function current:read()
      return observed
    end
    function current:watch(_, changed)
      self.subscriptions = self.subscriptions + 1
      callbacks[self] = changed
      return function()
        self.releases = self.releases + 1
      end
    end
    observations[id] = current
    return current
  end

  local function attach(root)
    ctx.observation = root
    local session = RenderSession.new(root, function(source, resources)
      applied[#applied + 1] = { source = source, resources = resources }
    end)
    sessions[#sessions + 1] = session
    session:attach()
    return session
  end

  before_each(function()
    sessions, observations, callbacks, scheduled, applied = {}, {}, {}, {}, {}
    old_server, old_observation = state.opencode_server, ctx.observation
    old_throttle = config.ui.output.rendering.event_throttle_ms
    old_collapsing = config.ui.output.rendering.event_collapsing
    config.ui.output.rendering.event_throttle_ms = 40
    config.ui.output.rendering.event_collapsing = true
    ctx:reset()
    state.jobs.set_server({
      is_ready = function()
        return true
      end,
      observe = function(_, ref)
        return observations[ref.id]
      end,
    })
    schedule_stub = stub(vim, 'schedule').invokes(function(callback)
      scheduled[#scheduled + 1] = { callback = callback, delay = 0 }
    end)
    defer_stub = stub(vim, 'defer_fn').invokes(function(callback, delay)
      scheduled[#scheduled + 1] = { callback = callback, delay = delay }
    end)
  end)

  after_each(function()
    for _, session in ipairs(sessions) do
      session:close()
    end
    schedule_stub:revert()
    defer_stub:revert()
    config.ui.output.rendering.event_throttle_ms = old_throttle
    config.ui.output.rendering.event_collapsing = old_collapsing
    state.jobs.set_server(old_server)
    ctx:reset()
    ctx.observation = old_observation
  end)

  it('keeps root and child deadlines separate and drains each once before detachment', function()
    local child = observation('child')
    local root = observation('root', { 'child' })
    local session = attach(root)
    session:sync_children()
    ctx.render_state:set_message({ id = 'existing' })
    for _ = 1, 100 do
      callbacks[root](root, 'messages')
    end
    callbacks[root](root, 'permissions')
    callbacks[child](child, 'messages')
    assert.equals(2, #scheduled)
    assert.equals(40, scheduled[1].delay)
    assert.equals(0, scheduled[2].delay)

    session:drain()
    assert.equals(2, #applied)
    assert.equals(root, applied[1].source)
    assert.same({ messages = true, permissions = true }, applied[1].resources)
    assert.equals(child, applied[2].source)
    for _, call in ipairs(scheduled) do
      call.callback()
    end
    assert.equals(2, #applied)
  end)

  it('retains known children during recovery and releases only children proven absent', function()
    local evicted, retained = observation('evicted'), observation('retained')
    local root = observation('root', { 'evicted', 'retained' })
    local session = attach(root)
    session:sync_children()
    root:read().sync.children.state = 'loading'
    root:read().children.order = {}
    session:sync_children()
    assert.equals(evicted, session:child('evicted'))
    assert.equals(0, evicted.releases)

    callbacks[evicted](evicted, 'messages')
    callbacks[retained](retained, 'questions')
    root:read().sync.children.state = 'current'
    root:read().children.order = { 'retained' }
    session:sync_children()
    callbacks[evicted](evicted, 'messages')
    session:drain()
    assert.equals(1, evicted.releases)
    assert.equals(0, retained.releases)
    assert.equals(1, retained.subscriptions)
    assert.equals(1, #applied)
    assert.equals(retained, applied[1].source)
    assert.same({ questions = true }, applied[1].resources)
  end)

  it('releases root and descendants once and ignores their callbacks after replacement', function()
    local grandchild = observation('grandchild')
    local child = observation('child', { 'grandchild' })
    local root = observation('root', { 'child' })
    local session = attach(root)
    session:attach()
    session:sync_children()
    callbacks[root](root, 'messages')
    callbacks[grandchild](grandchild, 'questions')
    local old_callbacks = { scheduled[1].callback, scheduled[2].callback }
    session:close()
    session:close()
    for _, current in ipairs({ root, child, grandchild }) do
      assert.equals(1, current.subscriptions)
      assert.equals(1, current.releases)
    end

    local replacement = observation('replacement')
    local next_session = attach(replacement)
    callbacks[replacement](replacement, 'messages')
    callbacks[root](root, 'messages')
    callbacks[grandchild](grandchild, 'questions')
    for _, callback in ipairs(old_callbacks) do
      callback()
    end
    assert.equals(0, #applied)
    assert.is_true(ctx.reconcile_scheduled)
    next_session:drain()
    assert.equals(1, #applied)
    assert.equals(replacement, applied[1].source)
  end)

  it('visits a shared descendant once even when child references contain a cycle', function()
    local shared = observation('shared', { 'root' })
    local first = observation('first', { 'shared' })
    local second = observation('second', { 'shared' })
    local root = observation('root', { 'first', 'second' })
    local session = attach(root)
    local tree = session:sync_children()
    assert.equals(4, #tree)
    for _, current in ipairs({ root, first, second, shared }) do
      assert.equals(1, current.subscriptions)
    end
  end)
end)
