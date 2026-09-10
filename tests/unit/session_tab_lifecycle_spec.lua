local state = require('opencode.state')
local tabs = state.session_tabs
local config = require('opencode.config')
local Promise = require('opencode.promise')
local stub = require('luassert.stub')
local session_runtime = require('opencode.services.session_runtime')

describe('session tab lifecycle', function()
  local original_state
  local original_hooks
  local stubs

  before_each(function()
    vim.wait(20)
    original_state = vim.deepcopy(state.store.state())
    original_hooks = config.hooks
    stubs = {}
    tabs.reset()
  end)

  after_each(function()
    state.store.unsubscribe('user_message_count', session_runtime._on_user_message_count_change)
    vim.wait(20)
    for _, replacement in ipairs(stubs) do
      replacement:revert()
    end
    config.hooks = original_hooks
    tabs.reset()
    for key in pairs(state.store.state()) do
      state.store.set_raw(key, nil)
    end
    for key, value in pairs(original_state) do
      state.store.set_raw(key, value)
    end
  end)

  local function replace(module, name, value)
    local replacement = stub(module, name).returns(value)
    table.insert(stubs, replacement)
    return replacement
  end

  it('notifies only when all requests complete, including in a background tab', function()
    local context = require('opencode.context')
    local messaging = require('opencode.services.messaging')
    local first = tabs.ensure_current()
    state.session.set_active({ id = 'first' })
    state.model.set_model('provider/model')
    state.model.clear_mode()
    replace(context, 'load', nil)
    replace(context, 'format_message', Promise.new():resolve({}))
    replace(context, 'unload_attachments', nil)
    replace(messaging, 'after_run', nil)
    replace(require('opencode.config_file'), 'get_opencode_agents', Promise.new():resolve({}))
    replace(require('opencode.session'), 'get_by_id', Promise.new():resolve({ id = 'first' }))

    local completed = {}
    config.hooks = {
      on_done_thinking = function(session)
        table.insert(completed, session.id)
      end,
    }
    local requests = {}
    state.jobs.set_api_client({
      create_message = function()
        local request = Promise.new()
        table.insert(requests, request)
        return request
      end,
    })
    state.store.subscribe('user_message_count', session_runtime._on_user_message_count_change)

    local send_one = messaging.send_message('one')
    local send_two = messaging.send_message('two')
    assert.equals(2, #requests)
    local second = tabs.create({ id = 'second' })
    tabs.activate(second)
    vim.wait(30)
    assert.same({}, completed)

    requests[1]:resolve({ info = { id = 'one' }, parts = {} })
    send_one:wait()
    assert.same({}, completed)
    requests[2]:resolve({ info = { id = 'two' }, parts = {} })
    send_two:wait()
    vim.wait(30)
    assert.same({ 'first' }, completed)
    assert.equals(0, first.user_message_count.first)
    assert.same({}, state.user_message_count)
    tabs.activate(first)
    vim.wait(30)
    assert.same({ 'first' }, completed)
  end)

  it('preserves tab variants while applying saved variants to actual model changes', function()
    replace(require('opencode.model_state'), 'get_variant', 'medium')
    local first = tabs.ensure_current()
    state.model.set_model('provider/first')
    assert.equals('medium', state.current_variant)
    state.model.set_variant('high')
    local second = tabs.create({ id = 'second' })
    tabs.activate(second)
    state.model.set_model('provider/second')
    assert.equals('medium', state.current_variant)
    state.model.clear_variant()

    tabs.activate(first)
    vim.wait(30)
    assert.equals('high', state.current_variant)
    tabs.activate(second)
    vim.wait(30)
    assert.is_nil(state.current_variant)
    state.model.set_model('provider/second')
    assert.is_nil(state.current_variant)
    state.model.set_model('provider/third')
    assert.equals('medium', state.current_variant)
  end)

  it('does not close the active tab when given an unknown tab id', function()
    local current = tabs.ensure_current()

    assert.is_false(session_runtime.close_session_tab('missing-tab'))
    assert.equals(current, tabs.current())
  end)
end)
