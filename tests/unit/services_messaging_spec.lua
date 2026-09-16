local loaded = rawget(_G, '__opencode_service_spec_loaded') or {}
_G.__opencode_service_spec_loaded = loaded
if loaded.services_messaging_spec then
  return
end
loaded.services_messaging_spec = true

local messaging = require('opencode.services.messaging')
local config = require('opencode.config')
local config_file = require('opencode.config_file')
local context = require('opencode.context')
local state = require('opencode.state')
local session_tabs = require('opencode.state.session_tabs')
local Promise = require('opencode.promise')
local stub = require('luassert.stub')
local assert = require('luassert')
local support = require('tests.unit.services_spec_support')

local function successful_submission(message)
  return Promise.new():resolve({ kind = 'reply', input_id = 'msg-user', message = message or { id = 'msg-reply' } })
end

describe('opencode.services.messaging', function()
  local connection

  before_each(function()
    connection = support.mock_connection()
  end)

  it('sends frozen input through the active Observation', function()
    state.ui.set_windows({ mock = 'windows' })
    state.session.set_active({ id = 'sess1' })

    local create_called = false
    local orig = state.session.active_observation().submit
    state.session.active_observation().submit = function(_, params)
      create_called = true
      assert.equal('hello world', params.text)
      assert.same({}, params.context)
      assert.same({}, params.files)
      assert.same({}, params.agents)
      return successful_submission()
    end

    messaging.send_message('hello world')
    vim.wait(50, function()
      return create_called
    end)
    assert.True(create_called)
    state.session.active_observation().submit = orig
  end)

  it('returns false when active session is missing', function()
    state.ui.set_windows({ mock = 'windows' })
    state.session.set_active(nil)

    local sent = messaging.send_message('hello world'):wait()
    assert.is_false(sent)
  end)

  it('does not submit before the active session fact is current', function()
    state.session.set_active({ id = 'sess1' })
    local observation = state.session.active_observation()
    observation._state.session = nil
    observation._state.sync.session = { state = 'loading' }
    local submit = stub(observation, 'submit')

    assert.is_false(messaging.send_message('hello world'):wait())
    assert.stub(submit).was_not_called()
    submit:revert()
  end)

  it('rejects V2 per-message settings before changing the session or submitting', function()
    state.session.set_active({ id = 'sess-v2' })
    connection.protocol = 'v2'
    local calls = {}
    connection.operations.set_session_agent = function(received, session_id, agent)
      calls[#calls + 1] = { 'agent', received, session_id, agent }
      return Promise.new():resolve(true)
    end
    connection.operations.set_session_model = function(received, session_id, model)
      calls[#calls + 1] = { 'model', received, session_id, model }
      return Promise.new():resolve(true)
    end
    local observation = state.session.active_observation()
    local original_submit = observation.submit
    observation.submit = function()
      calls[#calls + 1] = { 'submit' }
      return successful_submission()
    end

    local ok, err = pcall(function()
      messaging.send_message('hello', { agent = 'plan', model = 'provider/model', variant = 'high' }):wait()
    end)

    assert.is_false(ok)
    assert.matches('does not support per%-message agent', tostring(err))
    assert.same({}, calls)
    observation.submit = original_submit
  end)

  it('applies the selected model to a V2 session before submitting', function()
    state.session.set_active({ id = 'sess-v2' })
    connection.protocol = 'v2'
    local previous_model = state.current_model
    local previous_variant = state.current_variant
    state.model.set_model('provider/selected-model')
    state.model.set_variant('high')
    local calls = {}
    connection.operations.set_session_model = function(received, session_id, model)
      calls[#calls + 1] = { operation = 'model', received = received, session_id = session_id, model = model }
      return Promise.new():resolve(true)
    end
    local observation = state.session.active_observation()
    local original_submit = observation.submit
    observation.submit = function()
      calls[#calls + 1] = { operation = 'submit' }
      return successful_submission()
    end

    messaging.send_message('hello'):wait()

    assert.same({
      operation = 'model',
      received = connection,
      session_id = 'sess-v2',
      model = { providerID = 'provider', id = 'selected-model', variant = 'high' },
    }, calls[1])
    assert.equals('submit', calls[2].operation)
    observation.submit = original_submit
    state.model.set_model(previous_model)
    state.model.set_variant(previous_variant)
  end)

  it('rejects a V2 default system prompt before submitting', function()
    state.session.set_active({ id = 'sess-v2' })
    connection.protocol = 'v2'
    local previous = config.values.default_system_prompt
    config.values.default_system_prompt = 'configured system prompt'
    local observation = state.session.active_observation()
    local submit = stub(observation, 'submit')

    local ok, err = pcall(function()
      messaging.send_message('hello'):wait()
    end)

    config.values.default_system_prompt = previous
    assert.is_false(ok)
    assert.matches('does not support a per%-message system prompt', tostring(err))
    assert.stub(submit).was_not_called()
    submit:revert()
  end)

  it('persist options in state when sending message', function()
    state.ui.set_windows({ mock = 'windows' })
    state.session.set_active({ id = 'sess1' })
    local orig = state.session.active_observation().submit

    stub(config_file, 'get_opencode_agents').returns(Promise.new():resolve({ 'plan', 'build' }))

    local create_called = false
    state.session.active_observation().submit = function(_, params)
      create_called = true
      assert.equal('hello world', params.text)
      return successful_submission()
    end

    messaging.send_message(
      'hello world',
      { context = { current_file = { enabled = false } }, agent = 'plan', model = 'test/model' }
    )
    assert.same(state.current_context_config, { current_file = { enabled = false } })
    assert.equal(state.current_mode, 'plan')
    assert.equal(state.current_model, 'test/model')
    assert.is_true(create_called)
    state.session.active_observation().submit = orig
    config_file.get_opencode_agents:revert()
  end)

  it('does not switch mode when agent is hidden', function()
    state.ui.set_windows({ mock = 'windows' })
    state.session.set_active({ id = 'sess1' })
    state.model.set_mode('build')

    stub(config_file, 'get_opencode_agents').returns(Promise.new():resolve({ 'plan', 'build' }))

    local captured_params = nil
    local orig = state.session.active_observation().submit
    state.session.active_observation().submit = function(_, params)
      captured_params = params
      return successful_submission()
    end

    messaging.send_message('hello world', { agent = 'hidden-xyz' })
    vim.wait(50, function()
      return captured_params ~= nil
    end)

    assert.equal('build', state.current_mode)
    assert.equal('hidden-xyz', captured_params.agent)

    state.session.active_observation().submit = orig
    config_file.get_opencode_agents:revert()
  end)

  it('switches mode when agent is visible', function()
    state.ui.set_windows({ mock = 'windows' })
    state.session.set_active({ id = 'sess1' })
    state.model.set_mode('build')

    stub(config_file, 'get_opencode_agents').returns(Promise.new():resolve({ 'plan', 'build' }))

    local captured_params = nil
    local orig = state.session.active_observation().submit
    state.session.active_observation().submit = function(_, params)
      captured_params = params
      return successful_submission()
    end

    messaging.send_message('hello world', { agent = 'plan' })
    vim.wait(50, function()
      return captured_params ~= nil
    end)

    assert.equal('plan', state.current_mode)
    assert.equal('plan', captured_params.agent)

    state.session.active_observation().submit = orig
    config_file.get_opencode_agents:revert()
  end)

  it('returns false when active session is a child session', function()
    state.ui.set_windows({ mock = 'windows' })
    state.session.set_active({ id = 'child1', parentID = 'parent1' })
    connection.session_facts.child1 = { parentID = 'parent1' }

    local create_called = false
    local orig = state.session.active_observation().submit
    state.session.active_observation().submit = function()
      create_called = true
      return successful_submission()
    end

    local sent = messaging.send_message('hello world'):wait()
    assert.is_false(sent)
    assert.is_false(create_called)
    state.session.active_observation().submit = orig
  end)

  it('sends message to child session when child_readonly is false', function()
    state.ui.set_windows({ mock = 'windows' })
    state.session.set_active({ id = 'child1', parentID = 'parent1' })
    connection.session_facts.child1 = { parentID = 'parent1' }
    local config = require('opencode.config')
    local orig_readonly = config.values.child_readonly
    config.values.child_readonly = false

    stub(config_file, 'get_opencode_agents').returns(Promise.new():resolve({ 'build' }))

    local create_called = false
    local orig = state.session.active_observation().submit
    state.session.active_observation().submit = function()
      create_called = true
      return successful_submission()
    end

    messaging.send_message('hello world')
    vim.wait(50, function()
      return create_called
    end)
    assert.is_true(create_called)
    state.session.active_observation().submit = orig
    config.values.child_readonly = orig_readonly
    config_file.get_opencode_agents:revert()
  end)

  it('sends inferred agent for child session', function()
    state.ui.set_windows({ mock = 'windows' })
    state.model.set_mode('study') -- set by switch_session inference
    state.session.set_active({ id = 'child1', parentID = 'parent1' })
    connection.session_facts.child1 = { parentID = 'parent1' }
    local config = require('opencode.config')
    local orig_readonly = config.values.child_readonly
    config.values.child_readonly = false

    local captured_params = nil
    local orig = state.session.active_observation().submit
    state.session.active_observation().submit = function(_, params)
      captured_params = params
      return successful_submission()
    end

    messaging.send_message('hello world')
    vim.wait(50, function()
      return captured_params ~= nil
    end)

    assert.equal('study', captured_params.agent)
    state.session.active_observation().submit = orig
    config.values.child_readonly = orig_readonly
  end)

  it('respects explicit agent for child session', function()
    state.ui.set_windows({ mock = 'windows' })
    state.session.set_active({ id = 'child1', parentID = 'parent1' })
    connection.session_facts.child1 = { parentID = 'parent1' }
    local config = require('opencode.config')
    local orig_readonly = config.values.child_readonly
    config.values.child_readonly = false

    stub(config_file, 'get_opencode_agents').returns(Promise.new():resolve({ 'study', 'build' }))

    local captured_params = nil
    local orig = state.session.active_observation().submit
    state.session.active_observation().submit = function(_, params)
      captured_params = params
      return successful_submission()
    end

    messaging.send_message('hello world', { agent = 'study' })
    vim.wait(50, function()
      return captured_params ~= nil
    end)

    assert.equal('study', captured_params.agent)
    state.session.active_observation().submit = orig
    config.values.child_readonly = orig_readonly
    config_file.get_opencode_agents:revert()
  end)

  it('sends agent param for parent session', function()
    state.ui.set_windows({ mock = 'windows' })
    state.model.set_mode('build')
    state.session.set_active({ id = 'sess1' })

    stub(config_file, 'get_opencode_agents').returns(Promise.new():resolve({ 'build' }))

    local captured_params = nil
    local orig = state.session.active_observation().submit
    state.session.active_observation().submit = function(_, params)
      captured_params = params
      return successful_submission()
    end

    messaging.send_message('hello world')
    vim.wait(50, function()
      return captured_params ~= nil
    end)

    assert.equal('build', captured_params.agent)
    state.session.active_observation().submit = orig
    config_file.get_opencode_agents:revert()
  end)

  it('increments and decrements user_message_count correctly', function()
    state.ui.set_windows({ mock = 'windows' })
    state.session.set_active({ id = 'sess1' })
    state.session.set_user_message_count({})

    local count_before = state.user_message_count['sess1'] or 0
    local count_during = nil

    local orig = state.session.active_observation().submit
    state.session.active_observation().submit = function()
      count_during = state.user_message_count['sess1']
      return successful_submission({
        id = 'm1',
        content = {},
      })
    end

    messaging.send_message('hello world'):wait()

    local count_after = state.user_message_count['sess1'] or 0

    assert.equal(0, count_before)
    assert.equal(1, count_during)
    assert.equal(0, count_after)

    state.session.active_observation().submit = orig
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
    local observation = state.session.active_observation()
    observation.submit = function(_, params)
      sent_session = observation:read().session.id
      sent_params = params
      return successful_submission({ id = 'message-one', content = {} })
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

    local orig = state.session.active_observation().submit
    state.session.active_observation().submit = function()
      count_during = state.user_message_count['sess1']
      return Promise.new():reject('Test error')
    end

    messaging.send_message('hello world'):wait()

    local count_after = state.user_message_count['sess1'] or 0

    assert.equal(0, count_before)
    assert.equal(1, count_during)
    assert.equal(0, count_after)
    assert.same({ '/tmp/attached.lua' }, context.get_context().mentioned_files)
    assert.equals(1, #context.get_context().selections)

    state.session.active_observation().submit = orig
    for key, value in pairs(original_context) do
      context.get_context()[key] = value
    end
  end)

  it('surfaces an unknown V2 wait without consuming it as success', function()
    state.session.set_active({ id = 'sess_v2' })
    connection.protocol = 'v2'
    local observation = state.session.active_observation()
    observation.submit = function()
      return Promise.new():resolve({ kind = 'accepted', input = { id = 'msg-user' } })
    end
    observation.wait_until_idle = function()
      return Promise.new():reject('admission_unknown')
    end
    local after_run = stub(messaging, 'after_run')

    local result = messaging.send_message('hello'):wait()

    assert.is_nil(result)
    assert.stub(after_run).was_called(1)
    after_run:revert()
  end)

  it('keeps attachments until the submitted prompt succeeds', function()
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
    local original_create_message = state.session.active_observation().submit
    state.session.active_observation().submit = function()
      observed_context = vim.deepcopy(context.get_context())
      return successful_submission()
    end

    messaging.send_message('hello world'):wait()

    assert.same({ '/tmp/attached.lua' }, observed_context.mentioned_files)
    assert.equals(1, #observed_context.selections)
    assert.same({}, context.get_context().mentioned_files)
    assert.same({}, context.get_context().selections)

    state.session.active_observation().submit = original_create_message
    for key, value in pairs(original_context) do
      context.get_context()[key] = value
    end
  end)

  it('keeps user_message_count nonzero until an accepted submission reaches session idle', function()
    state.session.set_active({ id = 'sess1' })
    state.session.set_user_message_count({})
    local done = Promise.new()
    connection.protocol = 'v2'
    local observation = state.session.active_observation()
    local original_submit = observation.submit
    observation.submit = function()
      return Promise.new():resolve({ kind = 'accepted', input = { id = 'msg-user' } })
    end
    observation.wait_until_idle = function()
      return done
    end

    local sending = messaging.send_message('hello world')
    assert.is_true(vim.wait(100, function()
      return state.user_message_count.sess1 == 1
    end))
    assert.is_false(sending:is_resolved())
    done:resolve({ kind = 'session_idle', outcome = 'succeeded' })
    assert.equals('session_idle', sending:wait().kind)
    assert.equals(0, state.user_message_count.sess1)

    observation.submit = original_submit
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
