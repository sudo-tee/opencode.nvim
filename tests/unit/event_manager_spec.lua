local EventManager = require('opencode.event_manager')
local Promise = require('opencode.promise')
local state = require('opencode.state')
local config = require('opencode.config')

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

  it('does not duplicate the same event callback', function()
    local callback_called = 0
    local callback = function()
      callback_called = callback_called + 1
    end

    event_manager:subscribe('test_event', callback)
    event_manager:subscribe('test_event', callback)

    assert.are.equal(1, event_manager:get_subscriber_count('test_event'))

    event_manager:emit('test_event', {})

    vim.wait(100, function()
      return callback_called > 0
    end)

    assert.are.equal(1, callback_called)
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

  it('does not duplicate opencode_server listener across restart', function()
    local original_defer_fn = vim.defer_fn
    vim.defer_fn = function(fn, _)
      fn()
    end

    local original_subscribe_to_server_events = event_manager._subscribe_to_server_events
    local subscribe_calls = 0

    event_manager._subscribe_to_server_events = function()
      subscribe_calls = subscribe_calls + 1
    end

    local function resolved(value)
      local p = Promise.new()
      p:resolve(value)
      return p
    end

    local fake_server = {
      url = 'http://127.0.0.1:4000',
      get_spawn_promise = function(self)
        return resolved(self)
      end,
      get_shutdown_promise = function()
        return resolved(true)
      end,
    }

    state.opencode_server = nil

    event_manager:start()
    event_manager:stop()
    event_manager:start()

    state.opencode_server = fake_server

    vim.wait(200, function()
      return subscribe_calls > 0
    end)

    assert.are.equal(1, subscribe_calls)

    state.opencode_server = nil
    event_manager._subscribe_to_server_events = original_subscribe_to_server_events
    vim.defer_fn = original_defer_fn
  end)

  it('normalizes message.part.delta into message.part.updated', function()
    local original_event_collapsing = config.ui.output.rendering.event_collapsing
    config.ui.output.rendering.event_collapsing = true

    local received = {}
    event_manager:subscribe('message.part.updated', function(data)
      table.insert(received, vim.deepcopy(data.part))
    end)

    event_manager:_on_drained_events({
      {
        type = 'message.part.updated',
        properties = {
          part = {
            id = 'part_1',
            messageID = 'msg_1',
            sessionID = 'ses_1',
            type = 'text',
            text = '',
          },
        },
      },
      {
        type = 'message.part.delta',
        properties = {
          partID = 'part_1',
          messageID = 'msg_1',
          sessionID = 'ses_1',
          field = 'text',
          delta = 'hello',
        },
      },
      {
        type = 'message.part.delta',
        properties = {
          partID = 'part_1',
          messageID = 'msg_1',
          sessionID = 'ses_1',
          field = 'text',
          delta = ' world',
        },
      },
    })

    config.ui.output.rendering.event_collapsing = original_event_collapsing

    assert.are.equal(1, #received)
    assert.are.equal('hello world', received[1].text)
  end)

  it('keeps accumulated delta text across event batches', function()
    local received = {}
    event_manager:subscribe('message.part.updated', function(data)
      table.insert(received, vim.deepcopy(data.part))
    end)

    event_manager:_on_drained_events({
      {
        type = 'message.part.updated',
        properties = {
          part = {
            id = 'part_2',
            messageID = 'msg_2',
            sessionID = 'ses_2',
            type = 'text',
            text = '',
          },
        },
      },
    })

    event_manager:_on_drained_events({
      {
        type = 'message.part.delta',
        properties = {
          partID = 'part_2',
          messageID = 'msg_2',
          sessionID = 'ses_2',
          field = 'text',
          delta = 'abc',
        },
      },
    })

    assert.are.equal('abc', received[#received].text)
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
