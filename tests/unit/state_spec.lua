-- tests/unit/state_spec.lua
-- Tests for the observable state module

local state = require('opencode.state')
local store = require('opencode.state.store')

describe('opencode.state (observable)', function()
  it('notifies listeners on key change', function()
    local called = false
    local changed_key, new_val, old_val
    state.subscribe('messages', function(key, newv, oldv)
      called = true
      changed_key = key
      new_val = newv
      old_val = oldv
    end)
    state.renderer.set_messages({ { id = 'test' } })
    vim.wait(50, function()
      return called == true
    end)
    assert.is_true(called)
    assert.equals('messages', changed_key)
    assert.same({ { id = 'test' } }, new_val)
    -- Clean up
    state.renderer.set_messages(nil)
    state.unsubscribe('messages', nil)
  end)

  it('notifies wildcard listeners on any key change', function()
    local called = false
    local changed_key, new_val, old_val
    state.subscribe('*', function(key, newv, oldv)
      called = true
      changed_key = key
      new_val = newv
      old_val = oldv
    end)
    state.renderer.set_cost(99)
    vim.wait(50, function()
      return called == true
    end)
    assert.is_true(called)
    assert.equals('cost', changed_key)
    assert.equals(99, new_val)
    -- Clean up
    state.renderer.set_cost(0)
    state.unsubscribe('*', nil)
  end)

  it('can unregister listeners', function()
    local called = 0
    local cb = function()
      called = called + 1
    end
    state.subscribe('tokens_count', cb)
    state.renderer.set_tokens_count(1)
    vim.wait(50, function()
      return called == 1
    end)
    state.unsubscribe('tokens_count', cb)
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

    state.subscribe('cost', cb)
    state.subscribe('cost', cb)

    state.renderer.set_cost(1)
    vim.wait(50, function()
      return called > 0
    end)

    assert.equals(1, called)

    state.unsubscribe('cost', cb)
    state.renderer.set_cost(0)
  end)

  it('does not notify if value is unchanged', function()
    local called = false
    state.subscribe('tokens_count', function()
      called = true
    end)
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
    state.unsubscribe('tokens_count', nil)
  end)

  it('errors on direct state write', function()
    assert.has_error(function()
      state.messages = {}
    end)
  end)
end)
