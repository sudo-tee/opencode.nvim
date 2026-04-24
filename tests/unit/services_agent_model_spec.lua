local loaded = rawget(_G, '__opencode_service_spec_loaded') or {}
_G.__opencode_service_spec_loaded = loaded
if loaded.services_agent_model_spec then
  return
end
loaded.services_agent_model_spec = true

local agent_model = require('opencode.services.agent_model')
local config_file = require('opencode.config_file')
local state = require('opencode.state')
local Promise = require('opencode.promise')
local stub = require('luassert.stub')
local assert = require('luassert')

describe('opencode.services.agent_model', function()
  it('sets current model from config file when mode has a model configured', function()
    local agents_promise = Promise.new()
    agents_promise:resolve({ 'plan', 'build', 'custom' })
    local config_promise = Promise.new()
    config_promise:resolve({
      agent = {
        custom = {
          model = 'anthropic/claude-3-opus',
        },
      },
      model = 'gpt-4',
    })

    stub(config_file, 'get_opencode_agents').returns(agents_promise)
    stub(config_file, 'get_opencode_config').returns(config_promise)

    state.store.set('current_mode', nil)
    state.store.set('current_model', nil)
    state.store.set('user_mode_model_map', {})

    local promise = agent_model.switch_to_mode('custom')
    local success = promise:wait()

    assert.is_true(success)
    assert.equal('custom', state.current_mode)
    assert.equal('anthropic/claude-3-opus', state.current_model)

    config_file.get_opencode_agents:revert()
    config_file.get_opencode_config:revert()
  end)

  it('returns false when mode is invalid', function()
    local agents_promise = Promise.new()
    agents_promise:resolve({ 'plan', 'build' })

    stub(config_file, 'get_opencode_agents').returns(agents_promise)

    local promise = agent_model.switch_to_mode('nonexistent')
    local success = promise:wait()

    assert.is_false(success)

    config_file.get_opencode_agents:revert()
  end)

  it('returns false when mode is empty', function()
    local promise = agent_model.switch_to_mode('')
    local success = promise:wait()
    assert.is_false(success)

    promise = agent_model.switch_to_mode(nil)
    success = promise:wait()
    assert.is_false(success)
  end)

  it('respects user_mode_model_map priority: uses model stored in mode_model_map for mode', function()
    local agents_promise = Promise.new()
    agents_promise:resolve({ 'plan', 'build' })
    local config_promise = Promise.new()
    config_promise:resolve({
      agent = {
        plan = { model = 'gpt-4' },
      },
      model = 'gpt-3',
    })
    stub(config_file, 'get_opencode_agents').returns(agents_promise)
    stub(config_file, 'get_opencode_config').returns(config_promise)

    state.store.set('current_mode', nil)
    state.store.set('current_model', 'should-be-overridden')
    state.store.set('user_mode_model_map', { plan = 'anthropic/claude-3-haiku' })

    local promise = agent_model.switch_to_mode('plan')
    local success = promise:wait()
    assert.is_true(success)
    assert.equal('plan', state.current_mode)
    assert.equal('anthropic/claude-3-haiku', state.current_model)

    config_file.get_opencode_agents:revert()
    config_file.get_opencode_config:revert()
  end)

  it('falls back to config model if nothing else matches', function()
    local agents_promise = Promise.new()
    agents_promise:resolve({ 'plan', 'build' })
    local config_promise = Promise.new()
    config_promise:resolve({
      agent = {
        plan = {},
      },
      model = 'default-model',
    })
    stub(config_file, 'get_opencode_agents').returns(agents_promise)
    stub(config_file, 'get_opencode_config').returns(config_promise)
    state.store.set('current_mode', nil)
    state.store.set('current_model', 'old-model')
    state.store.set('user_mode_model_map', {})

    local promise = agent_model.switch_to_mode('plan')
    local success = promise:wait()
    assert.is_true(success)
    assert.equal('plan', state.current_mode)
    assert.equal('default-model', state.current_model)
    config_file.get_opencode_agents:revert()
    config_file.get_opencode_config:revert()
  end)

  it('keeps the current user-selected model and mode by default', function()
    state.model.set_model('openai/gpt-4.1')
    state.model.set_mode('plan')
    state.renderer.set_messages({
      {
        info = {
          id = 'm1',
          providerID = 'anthropic',
          modelID = 'claude-3-opus',
          mode = 'build',
        },
      },
    })

    local model = agent_model.initialize_current_model():wait()

    assert.equal('openai/gpt-4.1', model)
    assert.equal('openai/gpt-4.1', state.current_model)
    assert.equal('plan', state.current_mode)
  end)

  it('restores the latest session model and mode when explicitly requested', function()
    state.model.set_model('openai/gpt-4.1')
    state.model.set_mode('plan')
    state.renderer.set_messages({
      {
        info = {
          id = 'm1',
          providerID = 'anthropic',
          modelID = 'claude-3-opus',
          mode = 'build',
        },
      },
    })

    local model = agent_model.initialize_current_model({ restore_from_messages = true }):wait()

    assert.equal('anthropic/claude-3-opus', model)
    assert.equal('anthropic/claude-3-opus', state.current_model)
    assert.equal('build', state.current_mode)
  end)
end)
