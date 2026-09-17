local runtime = require('opencode.services.session_runtime')
local state = require('opencode.state')
local tabs = require('opencode.state.session_tabs')
local config_file = require('opencode.config_file')
local Promise = require('opencode.promise')
local stub = require('luassert.stub')

describe('active session observation', function()
  local connection, agents

  local function observation(id)
    local observed = {
      session = { id = id, title = id },
      sync = { session = { state = 'current' }, messages = { state = 'loading' } },
      entry_order = { 'message' },
      entries_by_id = {
        message = { id = 'message', model = { providerID = 'provider', modelID = id }, agent = 'plan' },
      },
    }
    local result = { facts = observed, subscriptions = 0, releases = 0 }
    function result:read()
      return observed
    end
    function result:watch(resources, callback)
      assert.same({ 'session', 'messages' }, resources)
      self.subscriptions = self.subscriptions + 1
      self.changed = function(resource)
        callback(self, resource)
      end
      return function()
        self.releases = self.releases + 1
      end
    end
    connection.observations[id] = result
    return result
  end

  local function settle()
    vim.wait(30, function() return false end)
  end

  local function activate(id)
    state.session.set_active({ id = id, title = 'Old title' })
    settle()
    return tabs.current()
  end

  before_each(function()
    tabs.reset()
    state.store.set_raw('active_session', nil)
    state.model.set_model('provider/previous')
    state.model.set_mode('build')
    tabs.ensure_current()
    agents = stub(config_file, 'get_opencode_agents').returns(Promise.new():resolve({ 'build', 'plan' }))
    connection = { observations = {}, is_ready = function() return true end }
    function connection:observe(ref)
      return assert(self.observations[ref.id])
    end
    state.jobs.set_server(connection)
    runtime.setup_subscriptions()
  end)

  after_each(function()
    runtime.setup_subscriptions(false)
    agents:revert()
    state.session.clear_active()
    state.jobs.clear_server()
    tabs.reset()
    settle()
  end)

  it('adopts current metadata and restores the model without a renderer', function()
    local source = observation('one')
    local tab = activate('one')
    assert.equals('one', state.active_session.title)
    assert.equals('one', tab.active_session.title)
    assert.equals('provider/previous', state.current_model)

    source.facts.sync.messages.state = 'current'
    source.changed('messages')
    assert.is_true(vim.wait(1000, function() return tab.model_restored_session_id == 'one' end))
    assert.equals('provider/one', state.current_model)
    assert.equals('plan', state.current_mode)

    state.model.set_model('provider/chosen')
    source.changed('messages')
    source.facts.session.title = 'Generated title'
    source.changed('session')
    settle()
    assert.equals('provider/chosen', state.current_model)
    assert.equals('Generated title', tab.active_session.title)
    assert.equals(1, source.subscriptions)
  end)

  it('waits for both metadata and messages to be current', function()
    local source = observation('one')
    source.facts.sync.session.state = 'loading'
    source.facts.sync.messages.state = 'current'
    activate('one')
    assert.equals('Old title', state.active_session.title)
    assert.equals('provider/previous', state.current_model)
    source.facts.sync.session.state = 'current'
    source.changed('session')
    assert.is_true(vim.wait(1000, function() return state.current_model == 'provider/one' end))
    assert.equals('one', state.active_session.title)
  end)

  it('ignores callbacks from a replaced session, even before scheduled rebinding', function()
    local first = observation('one')
    observation('two')
    activate('one')
    state.session.set_active({ id = 'two', title = 'Two' })
    first.facts.sync.messages.state = 'current'
    first.changed('messages')
    assert.equals('Two', state.active_session.title)
    settle()
    assert.equals('provider/previous', state.current_model)
    assert.equals(1, first.releases)
    first.changed('session')
    assert.equals('two', state.active_session.title)
  end)

  it('cancels model restoration while awaiting the agent list', function()
    local pending = Promise.new()
    agents:revert()
    agents = stub(config_file, 'get_opencode_agents').returns(pending)
    local first = observation('one')
    first.facts.sync.messages.state = 'current'
    observation('two')
    activate('one')
    assert.stub(agents).was_called(1)
    activate('two')
    state.model.set_model('provider/two-selected')
    pending:resolve({ 'plan', 'build' })
    settle()
    assert.equals('provider/two-selected', state.current_model)
    assert.equals('build', state.current_mode)
  end)

  it('preserves a chosen model when returning to a restored tab', function()
    local first = observation('one')
    first.facts.sync.messages.state = 'current'
    local first_tab = activate('one')
    assert.is_true(vim.wait(1000, function() return first_tab.model_restored_session_id == 'one' end))
    state.model.set_model('provider/chosen')
    tabs.sync()
    local second = observation('two')
    second.facts.sync.messages.state = 'current'
    local second_tab = tabs.create({ id = 'two' })
    tabs.activate(second_tab)
    assert.is_true(vim.wait(1000, function() return second_tab.model_restored_session_id == 'two' end))
    tabs.activate(first_tab)
    settle()
    assert.equals('provider/chosen', state.current_model)
    assert.equals('one', first_tab.model_restored_session_id)
  end)

  it('restores again when a different session replaces the current tab session', function()
    local first = observation('one')
    first.facts.sync.messages.state = 'current'
    local tab = activate('one')
    assert.is_true(vim.wait(1000, function() return tab.model_restored_session_id == 'one' end))
    local second = observation('two')
    second.facts.sync.messages.state = 'current'
    activate('two')
    assert.is_true(vim.wait(1000, function() return tab.model_restored_session_id == 'two' end))
    assert.equals('provider/two', state.current_model)
    activate('one')
    assert.is_true(vim.wait(1000, function() return tab.model_restored_session_id == 'one' end))
    assert.equals('provider/one', state.current_model)
  end)

  it('releases subscriptions on disconnect and teardown', function()
    local source = observation('one')
    activate('one')
    runtime.setup_subscriptions()
    assert.equals(1, source.subscriptions)
    state.jobs.clear_server()
    settle()
    assert.equals(1, source.releases)
    state.jobs.set_server(connection)
    settle()
    assert.equals(2, source.subscriptions)
    runtime.setup_subscriptions(false)
    assert.equals(2, source.releases)
    source.facts.session.title = 'After teardown'
    source.changed('session')
    assert.equals('one', state.active_session.title)
  end)

  it('reacquires an observation released while rebinding the same session to another tab', function()
    local source = observation('one')
    local watch = source.watch
    function source:watch(resources, callback)
      local release = watch(self, resources, callback)
      return function()
        release()
        connection.observations.one = nil
      end
    end
    function connection:observe(ref)
      return self.observations[ref.id] or observation(ref.id)
    end
    activate('one')
    local second_tab = tabs.create({ id = 'one' })
    tabs.activate(second_tab)
    settle()
    assert.equals(1, source.releases)
    local current = connection.observations.one
    assert.is_not_nil(current)
    assert.is_not_equal(source, current)
    assert.equals(1, current.subscriptions)
    current.facts.session.title = 'Current title'
    current.changed('session')
    assert.equals('Current title', second_tab.active_session.title)
  end)
end)
