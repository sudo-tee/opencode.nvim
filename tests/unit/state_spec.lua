-- tests/unit/state_spec.lua
-- Tests for the observable state module

local state = require('opencode.state')

describe('opencode.state (observable)', function()
  it('notifies listeners on key change', function()
    local called = false
    local changed_key, new_val, old_val
    local cb = function(key, newv, oldv)
      called = true
      changed_key = key
      new_val = newv
      old_val = oldv
    end
    state.store.subscribe('messages', cb)
    state.renderer.set_messages({ { id = 'test' } })
    vim.wait(50, function()
      return called == true
    end)
    assert.is_true(called)
    assert.equals('messages', changed_key)
    assert.same({ { id = 'test' } }, new_val)
    -- Clean up
    state.renderer.set_messages(nil)
    state.store.unsubscribe('messages', cb)
  end)

  it('notifies wildcard listeners on any key change', function()
    local called = false
    local changed_key, new_val, old_val
    local cb = function(key, newv, oldv)
      called = true
      changed_key = key
      new_val = newv
      old_val = oldv
    end
    state.store.subscribe('*', cb)
    state.renderer.set_cost(99)
    vim.wait(50, function()
      return called == true
    end)
    assert.is_true(called)
    assert.equals('cost', changed_key)
    assert.equals(99, new_val)
    -- Clean up
    state.renderer.set_cost(0)
    state.store.unsubscribe('*', cb)
  end)

  it('can unregister listeners', function()
    local called = 0
    local cb = function()
      called = called + 1
    end
    state.store.subscribe('tokens_count', cb)
    state.renderer.set_tokens_count(1)
    vim.wait(50, function()
      return called == 1
    end)
    state.store.unsubscribe('tokens_count', cb)
    state.renderer.set_tokens_count(2)
    vim.wait(50)
    assert.equals(1, called)
    -- Clean up
    state.renderer.set_tokens_count(0)
  end)

  it('does not register duplicate listeners for the same callback', function()
    local called = 0
    local cb = function()
      called = called + 1
    end

    state.store.subscribe('cost', cb)
    state.store.subscribe('cost', cb)

    state.renderer.set_cost(1)
    vim.wait(50, function()
      return called > 0
    end)

    assert.equals(1, called)

    state.store.unsubscribe('cost', cb)
    state.renderer.set_cost(0)
  end)

  it('does not notify if value is unchanged', function()
    local called = false
    local cb = function()
      called = true
    end
    state.store.subscribe('tokens_count', cb)
    state.renderer.set_tokens_count(42)
    vim.wait(50, function()
      return called == true
    end)
    called = false
    state.renderer.set_tokens_count(42)
    vim.wait(50)
    assert.is_false(called)
    -- Clean up
    state.renderer.set_tokens_count(0)
    state.store.unsubscribe('tokens_count', cb)
  end)

  it('errors on direct state write', function()
    assert.has_error(function()
      state.messages = {}
    end)
  end)

  it('batches notifications until commit', function()
    local calls = {}
    local messages_cb = function(key, newv, oldv)
      table.insert(calls, { key = key, newv = newv, oldv = oldv })
    end
    local cost_cb = function(key, newv, oldv)
      table.insert(calls, { key = key, newv = newv, oldv = oldv })
    end

    state.store.subscribe('messages', messages_cb)
    state.store.subscribe('cost', cost_cb)

    state.store.batch(function(store)
      store.set('messages', { { id = 'batched' } })
      store.set('cost', 12)
      assert.same({ { id = 'batched' } }, state.messages)
      assert.equals(12, state.cost)
      assert.equals(0, #calls)
    end)

    vim.wait(50, function()
      return #calls == 2
    end)

    assert.same('messages', calls[1].key)
    assert.same({ { id = 'batched' } }, calls[1].newv)
    assert.same('cost', calls[2].key)
    assert.equals(12, calls[2].newv)

    state.renderer.set_messages(nil)
    state.renderer.set_cost(0)
    state.store.unsubscribe('messages', messages_cb)
    state.store.unsubscribe('cost', cost_cb)
  end)

  it('emits after mutating table state in place', function()
    local called = false
    local received
    local cb = function(_, newv)
      called = true
      received = newv
    end

    state.renderer.set_messages({})
    state.store.subscribe('messages', cb)

    state.store.mutate('messages', function(messages)
      table.insert(messages, { id = 'mutated' })
    end)

    vim.wait(50, function()
      return called
    end)

    assert.is_true(called)
    assert.same({ { id = 'mutated' } }, received)

    state.renderer.set_messages(nil)
    state.store.unsubscribe('messages', cb)
  end)
end)
