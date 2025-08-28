-- tests/unit/state_spec.lua
-- Tests for the observable state module

local state = require('opencode.state')

describe('opencode.state (observable)', function()
  it('notifies listeners on key change', function()
    local called = false
    local changed_key, new_val, old_val
    state.subscribe('test_key', function(key, newv, oldv)
      called = true
      changed_key = key
      new_val = newv
      old_val = oldv
    end)
    state.test_key = 123
    assert.is_true(called)
    assert.equals('test_key', changed_key)
    assert.equals(123, new_val)
    assert.is_nil(old_val)
    -- Clean up
    state.test_key = nil
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
    state.another_key = 'abc'
    assert.is_true(called)
    assert.equals('another_key', changed_key)
    assert.equals('abc', new_val)
    assert.is_nil(old_val)
    -- Clean up
    state.another_key = nil
  end)

  it('can unregister listeners', function()
    local called = 0
    local cb = function()
      called = called + 1
    end
    state.subscribe('foo', cb)
    state.foo = 1
    state.unsubscribe('foo', cb)
    state.foo = 2
    assert.equals(1, called)
    -- Clean up
    state.foo = nil
  end)

  it('does not notify if value is unchanged', function()
    local called = false
    state.subscribe('bar', function()
      called = true
    end)
    state.bar = 42
    called = false
    state.bar = 42 -- set to same value
    assert.is_false(called)
    -- Clean up
    state.bar = nil
  end)
end)
