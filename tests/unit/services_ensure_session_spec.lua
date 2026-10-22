local assert = require('luassert')
local stub = require('luassert.stub')
local Promise = require('opencode.promise')
local state = require('opencode.state')
local tabs = require('opencode.state.session_tabs')
local runtime = require('opencode.services.session_runtime')
local support = require('tests.unit.services_spec_support')

describe('session_runtime.ensure_session', function()
  local connection
  local tab
  local create
  local creation
  local observation
  local changed
  local releases
  local deleted

  before_each(function()
    tabs.reset()
    connection = support.mock_connection()
    deleted = {}
    connection.operations.delete_session = function(_, id)
      deleted[#deleted + 1] = id
      return Promise.new():resolve(true)
    end
    state.session.set_active(nil)
    tab = tabs.ensure_current()
    creation = Promise.new()
    create = stub(runtime, 'create_detached_session').returns(creation)
    observation = connection:observe({ id = 'materialized' })
    observation._state.sync.session.state = 'loading'
    changed = nil
    releases = 0
    observation.watch = function(_, _, callback)
      changed = callback
      return function()
        releases = releases + 1
      end
    end
  end)

  after_each(function()
    tabs.reset()
    create:revert()
  end)

  local function finish_creation()
    creation:resolve({ session = { id = 'materialized' }, observation = observation, connection = connection })
    assert.is_true(vim.wait(1000, function()
      return changed ~= nil
    end))
  end

  local function hydrate()
    finish_creation()
    observation._state.sync.session.state = 'current'
    changed(observation)
  end

  it('keeps draft observation reads local and side-effect free', function()
    assert.is_nil(state.session.active_observation())
    assert.stub(create).was_not_called()
  end)

  it('shares creation and retains the subscription until every lease is released', function()
    local first = runtime.ensure_session()
    local second = runtime.ensure_session()
    hydrate()
    local first_lease = first:wait()
    local second_lease = second:wait()
    assert.stub(create).was_called(1)
    assert.equals(observation, first_lease.observation)
    assert.equals(observation, second_lease.observation)
    assert.equals('materialized', state.active_session.id)
    assert.is_nil(tab._draft_release)
    assert.same({}, deleted)
    first_lease.release()
    first_lease.release()
    assert.equals(0, releases)
    second_lease.release()
    second_lease.release()
    assert.equals(1, releases)
  end)

  it('reads already-current metadata without waiting for another watch notification', function()
    observation._state.sync.session.state = 'current'
    local pending = runtime.ensure_session()
    finish_creation()
    local lease = pending:wait()
    assert.equals(observation, lease.observation)
    lease.release()
  end)

  it('retains an independent lease when an operation starts after materialization', function()
    local subscriptions = 0
    observation.watch = function(_, _, callback)
      subscriptions = subscriptions + 1
      changed = callback
      return function()
        subscriptions = subscriptions - 1
        if subscriptions == 0 then
          observation._state.sync.session.state = 'unread'
        end
      end
    end
    local pending = runtime.ensure_session()
    hydrate()
    local first = pending:wait()
    local second = runtime.ensure_session():wait()
    assert.equals(2, subscriptions)
    first.release()
    assert.equals('current', observation._state.sync.session.state)
    assert.equals(1, subscriptions)
    second.release()
    assert.equals('unread', observation._state.sync.session.state)
  end)

  it('reuses an existing session without creating another', function()
    state.session.set_active({ id = 'existing' })
    local lease = runtime.ensure_session():wait()
    assert.equals('existing', lease.session.id)
    assert.equals(connection, lease.connection)
    assert.stub(create).was_not_called()
    lease.release()
  end)

  it('binds the new session to its original tab after a tab switch', function()
    local pending = runtime.ensure_session(tab.id)
    local other = tabs.create({ id = 'other-session' })
    tabs.activate(other)
    hydrate()
    local lease = pending:wait()
    assert.equals('materialized', tab.active_session.id)
    assert.equals('other-session', state.active_session.id)
    lease.release()
  end)

  it('cancels all waiters and deletes the session when their tab closes before creation completes', function()
    local first = runtime.ensure_session()
    local second = runtime.ensure_session()
    tabs.remove(tab)
    creation:resolve({ session = { id = 'materialized' }, observation = observation, connection = connection })
    assert.is_nil(first:wait())
    assert.is_nil(second:wait())
    assert.equals(0, releases)
    assert.is_nil(state.active_session)
    assert.same({ 'materialized' }, deleted)
  end)

  it('releases the metadata subscription and deletes the session when the tab closes during hydration', function()
    local pending = runtime.ensure_session()
    finish_creation()
    tabs.remove(tab)
    assert.is_nil(pending:wait())
    assert.equals(1, releases)
    assert.same({ 'materialized' }, deleted)
  end)

  it('does not bind a session after its connection changes', function()
    local pending = runtime.ensure_session()
    finish_creation()
    support.mock_connection()
    observation._state.sync.session.state = 'current'
    changed(observation)
    assert.is_nil(pending:wait())
    assert.is_nil(tab.active_session)
    assert.equals(1, releases)
    assert.same({ 'materialized' }, deleted)
  end)

  it('does not replace a session selected while its draft is materializing', function()
    local pending = runtime.ensure_session()
    finish_creation()
    state.session.set_active({ id = 'replacement' })
    observation._state.sync.session.state = 'current'
    changed(observation)
    assert.is_nil(pending:wait())
    assert.equals('replacement', state.active_session.id)
    assert.equals(1, releases)
    assert.same({ 'materialized' }, deleted)
  end)

  it('cleans up failed creation and allows retrying the same draft', function()
    local pending = runtime.ensure_session()
    creation:reject('creation failed')
    assert.is_nil(pending:wait())
    assert.is_nil(tab._draft_release)
    creation = Promise.new()
    create.returns(creation)
    local retry = runtime.ensure_session()
    hydrate()
    local lease = retry:wait()
    assert.stub(create).was_called(2)
    lease.release()
  end)

  it('releases failed metadata and leaves the tab as a draft', function()
    local pending = runtime.ensure_session()
    finish_creation()
    observation._state.sync.session.state = 'error'
    changed(observation)
    assert.is_nil(pending:wait())
    assert.is_nil(tab.active_session)
    assert.is_nil(tab._draft_release)
    assert.equals(1, releases)
    assert.same({ 'materialized' }, deleted)
  end)
end)
