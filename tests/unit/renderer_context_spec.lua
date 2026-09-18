local contexts = require('opencode.ui.renderer.ctx')
local tabs = require('opencode.state.session_tabs')
local state = require('opencode.state')
local renderer = require('opencode.ui.renderer')
local flush = require('opencode.ui.renderer.flush')
local symbols = require('opencode.ui.renderer.symbol_refresh')
local Promise = require('opencode.promise')
local stub = require('luassert.stub')

describe('renderer context ownership', function()
  local stubs, first, second

  local function replace(object, name, callback)
    local replacement = stub(object, name).invokes(callback)
    stubs[#stubs + 1] = replacement
    return replacement
  end

  before_each(function()
    stubs = {}
    renderer.setup_subscriptions(false)
    tabs.reset()
    state.store.set_raw('active_session', nil)
    state.store.set_raw('windows', nil)
    state.store.set_raw('opencode_server', nil)
    first = tabs.ensure_current()
    second = tabs.create({ id = 'two' })
  end)

  after_each(function()
    renderer.setup_subscriptions(false)
    tabs.reset()
    for _, replacement in ipairs(stubs) do
      replacement:revert()
    end
    state.store.set_raw('active_session', nil)
    state.store.set_raw('opencode_server', nil)
    vim.wait(20, function() return false end)
  end)

  it('selects persistent instances without copying or invalidating their fields', function()
    local a, b = first.renderer_context, second.renderer_context
    local cache = { key = 'first' }
    a.formatted_messages = cache
    a.lazy_render_count = 70
    a.bulk_mode = true
    local generation = a.generation
    tabs.activate(second)
    assert.equals(b, contexts.current())
    assert.is_not_equal(a.pending, b.pending)
    tabs.activate(first)
    assert.equals(a, contexts.current())
    assert.equals(cache, a.formatted_messages)
    assert.equals(70, a.lazy_render_count)
    assert.is_true(a.bulk_mode)
    assert.equals(generation, a.generation)
  end)

  it('holds an inactive flush without consuming another context pending work', function()
    local queued = {}
    replace(vim, 'schedule', function(callback) queued[#queued + 1] = callback end)
    local a, b = first.renderer_context, second.renderer_context
    a.pending.dirty_message_order = { 'first' }
    b.pending.dirty_message_order = { 'second' }
    flush.schedule(a)
    local flush_first = queued[#queued]
    tabs.activate(second)
    flush.schedule(b)
    local flush_second = queued[#queued]
    assert.equals(a.generation, b.generation)

    flush_first()
    assert.same({ 'first' }, a.pending.dirty_message_order)
    assert.same({ 'second' }, b.pending.dirty_message_order)
    assert.is_true(b.flush_scheduled)
    flush_second()
    assert.same({}, b.pending.dirty_message_order)
    assert.same({ 'first' }, a.pending.dirty_message_order)
  end)

  it('cancels a removed tab subscription and scheduled writes', function()
    local queued = {}
    replace(vim, 'schedule', function(callback) queued[#queued + 1] = callback end)
    local a, b = first.renderer_context, second.renderer_context
    local releases = 0
    a.render_session = { close = function() releases = releases + 1 end }
    flush.schedule(a)
    local pending = queued[#queued]
    tabs.activate(second)
    b.flush_scheduled = true
    tabs.remove(first)
    pending()
    assert.equals(1, releases)
    assert.is_true(a.closed)
    assert.is_nil(a.render_session)
    assert.is_true(b.flush_scheduled)
  end)

  it('debounces markdown separately and leaves inactive work on its owner', function()
    local timers = {}
    replace(require('opencode.util'), 'debounce', function(callback)
      local timer = { callback = callback }
      timers[#timers + 1] = timer
      return function(generation) timer.generation = generation end
    end)
    local a, b = first.renderer_context, second.renderer_context
    flush.trigger_on_data_rendered(a)
    tabs.activate(second)
    flush.trigger_on_data_rendered(b)
    assert.equals(2, #timers)
    timers[1].callback(timers[1].generation)
    assert.is_true(a.markdown_render_scheduled)
    assert.is_false(b.markdown_render_scheduled)
    a:close()
    timers[1].callback(timers[1].generation)
    assert.is_false(a.markdown_render_scheduled)
  end)

  it('finishes an inactive symbol refresh without clearing the active cycle', function()
    local queued = {}
    replace(vim, 'defer_fn', function(callback) queued[#queued + 1] = callback end)
    local refs = require('opencode.ui.reference_facts')
    replace(refs, 'refresh_current_files', function() end)
    replace(refs, 'available_files', function() return {} end)
    replace(require('opencode.ui.symbol_snapshot'), 'new_cycle', function() return {} end)
    state.store.set_raw('active_session', { id = 'one' })
    local a, b = first.renderer_context, second.renderer_context
    symbols.refresh(a)
    tabs.activate(second)
    symbols.refresh(b)
    local cycle = b.symbol_refresh_cycle
    queued[1]()
    vim.wait(20, function() return false end)
    assert.is_false(a.symbol_refresh_pending)
    assert.is_true(b.symbol_refresh_pending)
    assert.equals(cycle, b.symbol_refresh_cycle)
  end)

  it('does not render or scroll another tab when an older history request finishes', function()
    local request = Promise.new()
    local a = first.renderer_context
    state.store.set_raw('active_session', { id = 'one' })
    local message = { id = 'message', session_id = 'one', kind = 'assistant', content = {} }
    local observed = { session = { id = 'one' }, entry_order = { 'message' }, entries_by_id = { message = message } }
    a.entries = { message }
    a.lazy_render_count = 1
    a.observation = {
      read = function() return observed end,
      load_older = function() return request end,
    }
    assert.is_true(renderer.load_more_messages(a))
    tabs.activate(second)
    local renders = replace(renderer, 'render_from_cache', function() end)
    local scrolls = replace(renderer, 'restore_top_anchor', function() end)
    observed.entry_order = { 'older', 'message' }
    observed.entries_by_id.older = { id = 'older' }
    request:resolve()
    vim.wait(20, function() return false end)
    assert.stub(renders).was_not_called()
    assert.stub(scrolls).was_not_called()
    assert.equals(second.renderer_context, contexts.current())
  end)

  it('keeps subscriptions on their tabs and reconciles background facts on return', function()
    local function source(id)
      local message = { id = id, session_id = id, kind = 'assistant', content = {} }
      local observed = {
        session = { id = id },
        sync = { session = { state = 'current' }, messages = { state = 'current' } },
        entries_by_id = { [id] = message }, entry_order = { id },
        children = { order = {}, by_id = {} }, files = { revision = 0 },
      }
      local result = { subscriptions = 0, releases = 0 }
      function result:read() return observed end
      function result:watch(_, callback)
        self.subscriptions = self.subscriptions + 1
        self.changed = function() callback(self, 'session') end
        return function() self.releases = self.releases + 1 end
      end
      return result
    end
    local one, two = source('one'), source('two')
    state.store.set_raw('opencode_server', {
      is_ready = function() return true end,
      observe = function(_, ref) return ref.id == 'one' and one or two end,
    })
    state.store.set_raw('active_session', { id = 'one' })
    renderer.on_session_changed()
    local a, b = first.renderer_context, second.renderer_context
    local original_session = a.render_session
    tabs.activate(second)
    renderer.on_session_changed()
    one:read().entries_by_id.older = { id = 'older', session_id = 'one', kind = 'assistant', content = {} }
    table.insert(one:read().entry_order, 'older')
    one.changed()
    assert.is_true(vim.wait(1000, function() return a.needs_reconcile end))
    assert.equals(1, one.subscriptions)
    assert.equals(0, one.releases)
    assert.equals('two', b.entries[1].id)
    assert.equals(1, #b.entries)

    tabs.activate(first)
    renderer.on_session_changed()
    assert.equals(original_session, a.render_session)
    -- A mounted display is needed to reconcile, but buffer painting is tested separately.
    replace(require('opencode.ui.output_window'), 'mounted', function() return true end)
    replace(renderer, 'scroll_to_bottom', function() end)
    renderer.on_session_tab_changed(nil, first.id, second.id)
    assert.is_false(a.needs_reconcile)
    assert.equals(2, #a.entries)
    assert.equals(1, one.subscriptions)
    tabs.remove(second)
    assert.equals(1, two.releases)
  end)
end)
