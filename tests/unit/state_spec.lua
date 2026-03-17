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
end)
