local loaded = rawget(_G, '__opencode_service_spec_loaded') or {}
_G.__opencode_service_spec_loaded = loaded
if loaded.services_messaging_spec then
  return
end
loaded.services_messaging_spec = true

local messaging = require('opencode.services.messaging')
local session_runtime = require('opencode.services.session_runtime')
local config_file = require('opencode.config_file')
local context = require('opencode.context')
local state = require('opencode.state')
local session_tabs = require('opencode.state.session_tabs')
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

    stub(config_file, 'get_opencode_agents').returns(Promise.new():resolve({ 'plan', 'build' }))

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
    config_file.get_opencode_agents:revert()
  end)

  it('does not switch mode when agent is hidden', function()
    state.ui.set_windows({ mock = 'windows' })
    state.session.set_active({ id = 'sess1' })
    state.model.set_mode('build')

    stub(config_file, 'get_opencode_agents').returns(Promise.new():resolve({ 'plan', 'build' }))

    local captured_params = nil
    local orig = state.api_client.create_message
    state.api_client.create_message = function(_, sid, params)
      captured_params = params
      return Promise.new():resolve({ id = 'm1' })
    end

    messaging.send_message('hello world', { agent = 'hidden-xyz' })
    vim.wait(50, function()
      return captured_params ~= nil
    end)

    assert.equal('build', state.current_mode)
    assert.equal('hidden-xyz', captured_params.agent)

    state.api_client.create_message = orig
    config_file.get_opencode_agents:revert()
  end)

  it('switches mode when agent is visible', function()
    state.ui.set_windows({ mock = 'windows' })
    state.session.set_active({ id = 'sess1' })
    state.model.set_mode('build')

    stub(config_file, 'get_opencode_agents').returns(Promise.new():resolve({ 'plan', 'build' }))

    local captured_params = nil
    local orig = state.api_client.create_message
    state.api_client.create_message = function(_, sid, params)
      captured_params = params
      return Promise.new():resolve({ id = 'm1' })
    end

    messaging.send_message('hello world', { agent = 'plan' })
    vim.wait(50, function()
      return captured_params ~= nil
    end)

    assert.equal('plan', state.current_mode)
    assert.equal('plan', captured_params.agent)

    state.api_client.create_message = orig
    config_file.get_opencode_agents:revert()
  end)

  it('returns false when active session is a child session', function()
    state.ui.set_windows({ mock = 'windows' })
    state.session.set_active({ id = 'child1', parentID = 'parent1' })

    local create_called = false
    local orig = state.api_client.create_message
    state.api_client.create_message = function(_, sid, params)
      create_called = true
      return Promise.new():resolve({ id = 'm1' })
    end

    local sent = messaging.send_message('hello world'):wait()
    assert.is_false(sent)
    assert.is_false(create_called)
    state.api_client.create_message = orig
  end)

  it('sends message to child session when child_readonly is false', function()
    state.ui.set_windows({ mock = 'windows' })
    state.session.set_active({ id = 'child1', parentID = 'parent1' })
    local config = require('opencode.config')
    local orig_readonly = config.values.child_readonly
    config.values.child_readonly = false

    stub(config_file, 'get_opencode_agents').returns(Promise.new():resolve({ 'build' }))

    local create_called = false
    local orig = state.api_client.create_message
    state.api_client.create_message = function(_, sid, params)
      create_called = true
      return Promise.new():resolve({ id = 'm1' })
    end

    messaging.send_message('hello world')
    vim.wait(50, function()
      return create_called
    end)
    assert.is_true(create_called)
    state.api_client.create_message = orig
    config.values.child_readonly = orig_readonly
    config_file.get_opencode_agents:revert()
  end)

  it('sends inferred agent for child session', function()
    state.ui.set_windows({ mock = 'windows' })
    state.model.set_mode('study') -- set by switch_session inference
    state.session.set_active({ id = 'child1', parentID = 'parent1' })
    local config = require('opencode.config')
    local orig_readonly = config.values.child_readonly
    config.values.child_readonly = false

    local captured_params = nil
    local orig = state.api_client.create_message
    state.api_client.create_message = function(_, sid, params)
      captured_params = params
      return Promise.new():resolve({ id = 'm1' })
    end

    messaging.send_message('hello world')
    vim.wait(50, function()
      return captured_params ~= nil
    end)

    assert.equal('study', captured_params.agent)
    state.api_client.create_message = orig
    config.values.child_readonly = orig_readonly
  end)

  it('respects explicit agent for child session', function()
    state.ui.set_windows({ mock = 'windows' })
    state.session.set_active({ id = 'child1', parentID = 'parent1' })
    local config = require('opencode.config')
    local orig_readonly = config.values.child_readonly
    config.values.child_readonly = false

    stub(config_file, 'get_opencode_agents').returns(Promise.new():resolve({ 'study', 'build' }))

    local captured_params = nil
    local orig = state.api_client.create_message
    state.api_client.create_message = function(_, sid, params)
      captured_params = params
      return Promise.new():resolve({ id = 'm1' })
    end

    messaging.send_message('hello world', { agent = 'study' })
    vim.wait(50, function()
      return captured_params ~= nil
    end)

    assert.equal('study', captured_params.agent)
    state.api_client.create_message = orig
    config.values.child_readonly = orig_readonly
    config_file.get_opencode_agents:revert()
  end)

  it('sends agent param for parent session', function()
    state.ui.set_windows({ mock = 'windows' })
    state.model.set_mode('build')
    state.session.set_active({ id = 'sess1' })

    stub(config_file, 'get_opencode_agents').returns(Promise.new():resolve({ 'build' }))

    local captured_params = nil
    local orig = state.api_client.create_message
    state.api_client.create_message = function(_, sid, params)
      captured_params = params
      return Promise.new():resolve({ id = 'm1' })
    end

    messaging.send_message('hello world')
    vim.wait(50, function()
      return captured_params ~= nil
    end)

    assert.equal('build', captured_params.agent)
    state.api_client.create_message = orig
    config_file.get_opencode_agents:revert()
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

  it('keeps an in-flight send bound to its original tab and session', function()
    session_tabs.reset()
    local first = session_tabs.ensure_current()
    state.session.set_active({ id = 'session-one' })
    state.model.clear_model()
    state.model.set_mode('mode-one')
    local second = session_tabs.create({ id = 'session-two' })
    second.current_mode = 'mode-two'

    local config_promise = Promise.new()
    local config_stub = stub(config_file, 'get_opencode_config').returns(config_promise)
    local agents_stub =
      stub(config_file, 'get_opencode_agents').returns(Promise.new():resolve({ 'mode-one', 'mode-two' }))
    local sent_session
    local sent_params
    state.api_client.create_message = function(_, session_id, params)
      sent_session = session_id
      sent_params = params
      return Promise.new():resolve({ info = { id = 'message-one' }, parts = {} })
    end

    local send = messaging.send_message('hello world')
    session_tabs.activate(second)
    config_promise:resolve({ model = 'test/model' })
    send:wait()

    assert.equals('session-one', sent_session)
    assert.equals('mode-one', sent_params.agent)
    assert.equals('test/model', first.current_model)
    assert.equals('mode-two', state.current_mode)
    assert.is_nil(state.current_model)
    assert.equals(0, first.user_message_count['session-one'])
    assert.is_nil(second.user_message_count['session-one'])

    config_stub:revert()
    agents_stub:revert()
    session_tabs.reset()
  end)

  it('preserves attachments when message preparation fails', function()
    state.session.set_active({ id = 'session-one' })
    state.model.clear_model()
    local original_context = context.snapshot()
    context.get_context().mentioned_files = { '/tmp/attached.lua' }
    context.get_context().selections = {}
    local config_stub = stub(config_file, 'get_opencode_config').returns(Promise.new():reject('config failed'))

    local ok = pcall(function()
      messaging.send_message('hello world'):wait()
    end)

    assert.is_false(ok)
    assert.same({ '/tmp/attached.lua' }, context.get_context().mentioned_files)
    config_stub:revert()
    context.restore(original_context)
  end)

  it('decrements user_message_count on error', function()
    state.ui.set_windows({ mock = 'windows' })
    state.session.set_active({ id = 'sess1' })
    state.session.set_user_message_count({})

    local original_context = vim.deepcopy(context.get_context())
    context.get_context().mentioned_files = { '/tmp/attached.lua' }
    context.get_context().selections = {
      {
        file = { path = '/tmp/attached.lua', name = 'attached.lua', extension = 'lua' },
        content = 'selected',
        lines = '1, 2',
      },
    }

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
    assert.same({}, context.get_context().mentioned_files)
    assert.same({}, context.get_context().selections)

    state.api_client.create_message = orig
    session_runtime.cancel = orig_cancel
    for key, value in pairs(original_context) do
      context.get_context()[key] = value
    end
  end)

  it('clears attachments before the request is sent', function()
    state.ui.set_windows({ mock = 'windows' })
    state.session.set_active({ id = 'sess1' })

    local original_context = vim.deepcopy(context.get_context())
    context.get_context().mentioned_files = { '/tmp/attached.lua' }
    context.get_context().selections = {
      {
        file = { path = '/tmp/attached.lua', name = 'attached.lua', extension = 'lua' },
        content = 'selected',
        lines = '1, 2',
      },
    }

    local observed_context
    local original_create_message = state.api_client.create_message
    state.api_client.create_message = function(_, _session_id, _params)
      observed_context = vim.deepcopy(context.get_context())
      return Promise.new():resolve({ info = { id = 'm1' }, parts = {} })
    end

    messaging.send_message('hello world'):wait()

    assert.same({}, observed_context.mentioned_files)
    assert.same({}, observed_context.selections)

    state.api_client.create_message = original_create_message
    for key, value in pairs(original_context) do
      context.get_context()[key] = value
    end
  end)

  it('clears sent attachments from the active context', function()
    state.session.set_active({ id = 'sess1' })

    local original_context = vim.deepcopy(context.get_context())
    local sent_context = {
      current_file = nil,
      cursor_data = nil,
      linter_errors = nil,
      mentioned_files = { '/tmp/attached.lua' },
      mentioned_subagents = {},
      selections = {
        {
          file = { path = '/tmp/attached.lua', name = 'attached.lua', extension = 'lua' },
          content = 'selected',
          lines = '1, 2',
        },
      },
    }
    for key, value in pairs(sent_context) do
      context.get_context()[key] = value
    end

    local delta_stub = stub(context, 'delta_context')
    messaging.after_run('hello')

    assert.same({}, context.get_context().mentioned_files)
    assert.same({}, context.get_context().selections)

    delta_stub:revert()
    for key, value in pairs(original_context) do
      context.get_context()[key] = value
    end
  end)

  it('preserves a two-argument sent context passed to after_run', function()
    state.session.set_active({ id = 'sess1' })
    local sent_context = {
      mentioned_files = { '/tmp/attached.lua' },
      selections = { { content = 'selected' } },
    }
    local original_delta_context = context.delta_context
    context.delta_context = function() end

    messaging.after_run('hello', sent_context)

    assert.same(sent_context, state.last_sent_context)
    context.delta_context = original_delta_context
  end)
end)
