local EventManager = require('opencode.event_manager')

describe('EventManager', function()
  local event_manager

  before_each(function()
    event_manager = EventManager.new()
  end)

  after_each(function()
    if event_manager then
      event_manager:stop()
    end
  end)

  it('should create a new instance', function()
    assert.not_nil(event_manager)
    assert.is_false(event_manager.is_started)
    assert.are.same({}, event_manager.events)
  end)

  it('should subscribe and emit events', function()
    local callback_called = false
    local received_data = nil

    event_manager:subscribe('test_event', function(data)
      callback_called = true
      received_data = data
    end)

    event_manager:emit('test_event', { test = 'data' })

    -- Wait for scheduled callback to execute
    vim.wait(100, function()
      return callback_called
    end)

    assert.is_true(callback_called)
    assert.are.same({ test = 'data' }, received_data)
  end)

  it('should handle multiple subscribers', function()
    local callback1_called = false
    local callback2_called = false

    event_manager:subscribe('test_event', function(data)
      callback1_called = true
    end)

    event_manager:subscribe('test_event', function(data)
      callback2_called = true
    end)

    event_manager:emit('test_event', {})

    -- Wait for scheduled callbacks to execute
    vim.wait(100, function()
      return callback1_called and callback2_called
    end)

    assert.is_true(callback1_called)
    assert.is_true(callback2_called)
  end)

  it('should unsubscribe correctly', function()
    local callback_called = false
    local callback = function(data)
      callback_called = true
    end

    event_manager:subscribe('test_event', callback)
    event_manager:unsubscribe('test_event', callback)
    event_manager:emit('test_event', {})

    assert.is_false(callback_called)
  end)

  it('should track subscriber count', function()
    local callback1 = function() end
    local callback2 = function() end

    assert.are.equal(0, event_manager:get_subscriber_count('test_event'))

    event_manager:subscribe('test_event', callback1)
    assert.are.equal(1, event_manager:get_subscriber_count('test_event'))

    event_manager:subscribe('test_event', callback2)
    assert.are.equal(2, event_manager:get_subscriber_count('test_event'))

    event_manager:unsubscribe('test_event', callback1)
    assert.are.equal(1, event_manager:get_subscriber_count('test_event'))
  end)

  it('should list event names', function()
    event_manager:subscribe('event1', function() end)
    event_manager:subscribe('event2', function() end)

    local names = event_manager:get_event_names()
    table.sort(names)
    assert.are.same({ 'event1', 'event2' }, names)
  end)

  it('should handle starting and stopping', function()
    assert.is_false(event_manager.is_started)

    event_manager:start()
    assert.is_true(event_manager.is_started)

    event_manager:stop()
    assert.is_false(event_manager.is_started)
    assert.are.same({}, event_manager.events)
  end)

  it('should not start multiple times', function()
    event_manager:start()
    local first_start = event_manager.is_started

    event_manager:start() -- Should not do anything
    assert.are.equal(first_start, event_manager.is_started)
  end)

  describe('User autocmd events', function()
    it('should fire User autocmd when emitting events', function()
      local autocmd_called = false
      local autocmd_data = nil

      local autocmd_id = vim.api.nvim_create_autocmd('User', {
        pattern = 'OpencodeEvent:test_event',
        callback = function(args)
          autocmd_called = true
          autocmd_data = args.data
        end,
      })

      event_manager:emit('test_event', { test = 'value' })

      vim.wait(100, function()
        return autocmd_called
      end)

      vim.api.nvim_del_autocmd(autocmd_id)

      assert.is_true(autocmd_called)
      assert.are.same({
        event = {
          type = 'test_event',
          properties = { test = 'value' },
        },
      }, autocmd_data)
    end)

    it('should fire User autocmd even when no internal listeners exist', function()
      local autocmd_called = false

      local autocmd_id = vim.api.nvim_create_autocmd('User', {
        pattern = 'OpencodeEvent:orphan_event',
        callback = function(args)
          autocmd_called = true
        end,
      })

      event_manager:emit('orphan_event', { data = 'test' })

      vim.wait(100, function()
        return autocmd_called
      end)

      vim.api.nvim_del_autocmd(autocmd_id)

      assert.is_true(autocmd_called)
    end)
  end)
end)
