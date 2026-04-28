local loaded = rawget(_G, '__opencode_service_spec_loaded') or {}
_G.__opencode_service_spec_loaded = loaded
if loaded.services_messaging_spec then
  return
end
loaded.services_messaging_spec = true

local messaging = require('opencode.services.messaging')
local session_runtime = require('opencode.services.session_runtime')
local state = require('opencode.state')
local Promise = require('opencode.promise')
local stub = require('luassert.stub')
local assert = require('luassert')
local support = require('tests.unit.services_spec_support')

describe('opencode.services.messaging', function()
  before_each(function()
    support.mock_api_client()
  end)

  it('sends a message via api_client', function()
    state.ui.set_windows({ mock = 'windows' })
    state.session.set_active({ id = 'sess1' })

    local create_called = false
    local orig = state.api_client.create_message
    state.api_client.create_message = function(_, sid, params)
      create_called = true
      assert.equal('sess1', sid)
      assert.truthy(params.parts)
      return Promise.new():resolve({ id = 'm1' })
    end

    messaging.send_message('hello world')
    vim.wait(50, function()
      return create_called
    end)
    assert.True(create_called)
    state.api_client.create_message = orig
  end)

  it('returns false when active session is missing', function()
    state.ui.set_windows({ mock = 'windows' })
    state.session.set_active(nil)

    local sent = messaging.send_message('hello world'):wait()
    assert.is_false(sent)
  end)

  it('persist options in state when sending message', function()
    local orig = state.api_client.create_message
    state.ui.set_windows({ mock = 'windows' })
    state.session.set_active({ id = 'sess1' })

    local create_called = false
    state.api_client.create_message = function(_, sid, params)
      create_called = true
      assert.equal('sess1', sid)
      assert.truthy(params.parts)
      return Promise.new():resolve({ id = 'm1' })
    end

    messaging.send_message(
      'hello world',
      { context = { current_file = { enabled = false } }, agent = 'plan', model = 'test/model' }
    )
    assert.same(state.current_context_config, { current_file = { enabled = false } })
    assert.equal(state.current_mode, 'plan')
    assert.equal(state.current_model, 'test/model')
    assert.is_true(create_called)
    state.api_client.create_message = orig
  end)

  it('increments and decrements user_message_count correctly', function()
    state.ui.set_windows({ mock = 'windows' })
    state.session.set_active({ id = 'sess1' })
    state.session.set_user_message_count({})

    local count_before = state.user_message_count['sess1'] or 0
    local count_during = nil

    local orig = state.api_client.create_message
    state.api_client.create_message = function(_, sid, params)
      count_during = state.user_message_count['sess1']
      return Promise.new():resolve({
        id = 'm1',
        info = { id = 'm1' },
        parts = {},
      })
    end

    messaging.send_message('hello world'):wait()

    local count_after = state.user_message_count['sess1'] or 0

    assert.equal(0, count_before)
    assert.equal(1, count_during)
    assert.equal(0, count_after)

    state.api_client.create_message = orig
  end)

  it('decrements user_message_count on error', function()
    state.ui.set_windows({ mock = 'windows' })
    state.session.set_active({ id = 'sess1' })
    state.session.set_user_message_count({})

    local count_before = state.user_message_count['sess1'] or 0
    local count_during = nil

    local orig = state.api_client.create_message
    state.api_client.create_message = function(_, sid, params)
      count_during = state.user_message_count['sess1']
      return Promise.new():reject('Test error')
    end

    local orig_cancel = session_runtime.cancel
    stub(session_runtime, 'cancel').returns(Promise.new():resolve(nil))

    messaging.send_message('hello world'):wait()

    local count_after = state.user_message_count['sess1'] or 0

    assert.equal(0, count_before)
    assert.equal(1, count_during)
    assert.equal(0, count_after)

    state.api_client.create_message = orig
    session_runtime.cancel = orig_cancel
  end)
end)
