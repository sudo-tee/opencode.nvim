local assert = require('luassert')
local Promise = require('opencode.promise')
local transport = require('opencode.transport')

local function ready_connection(protocol, url)
  local connection = require('opencode.opencode_server').from_custom(url or ('http://' .. protocol .. '.test'))
  connection.protocol = protocol
  connection.server_identity = { version = protocol == 'v1' and '1.18.30' or '2.0.1' }
  connection.credential = { username = 'opencode' }
  return connection:mark_ready()
end

local function assert_empty_shape(state, session_id)
  assert.equals(session_id, state.session.id)
  assert.same({}, state.entries_by_id)
  assert.same({}, state.entry_order)
  assert.same({ by_id = {}, order = {} }, state.children)
  assert.same({ items_by_id = {}, order = {} }, state.inbox)
  assert.same({ activity = 'unknown' }, state.execution)
  assert.same({}, state.permission_requests_by_id)
  assert.same({}, state.question_requests_by_id)
  assert.same({ revision = 0 }, state.files)
  assert.is_nil(state.messages)
  assert.is_nil(state.raw_messages)
end

describe('protocol Observation lifecycle', function()
  local original_request, original_stream, io_calls

  before_each(function()
    original_request = transport.request
    original_stream = transport.stream
    io_calls = 0
    transport.request = function()
      io_calls = io_calls + 1
      return Promise.new()
    end
    transport.stream = function(connection)
      io_calls = io_calls + 1
      local handle = {}
      function handle:shutdown()
        self.stopped = true
      end
      connection:set_stream(handle)
      return handle
    end
  end)

  after_each(function()
    transport.request = original_request
    transport.stream = original_stream
  end)

  it('returns one Observation per Connection and session without I/O', function()
    local first_connection = ready_connection('v2', 'http://first.test')
    local second_connection = ready_connection('v2', 'http://second.test')
    local first = first_connection:observe({ id = 'ses-same' })

    assert.equals(first, first_connection:observe({ id = 'ses-same', location = { directory = '/ignored' } }))
    assert.not_equals(first, second_connection:observe({ id = 'ses-same' }))
    assert.equals(first, first_connection.observations['ses-same'])
    assert.equals(0, io_calls)
  end)

  it('constructs protocol-owned initial facts and sync states', function()
    local v1 = ready_connection('v1'):observe({ id = 'ses-v1', location = { directory = '/remote/project' } })
    local v2 = ready_connection('v2'):observe({ id = 'ses-v2' })
    local v1_state = v1:read()
    local v2_state = v2:read()

    assert_empty_shape(v1_state, 'ses-v1')
    assert_empty_shape(v2_state, 'ses-v2')
    assert.equals('/remote/project', v1_state.session.location.directory)
    assert.is_nil(v2_state.session.location)
    for _, resource in ipairs({ 'session', 'children', 'messages', 'execution', 'permissions', 'questions', 'files' }) do
      assert.equals('unread', v1_state.sync[resource].state)
      assert.equals('unread', v2_state.sync[resource].state)
    end
    assert.equals('unsupported', v1_state.sync.inbox.state)
    assert.matches('no session inbox', v1_state.sync.inbox.error)
    assert.equals('unread', v2_state.sync.inbox.state)
    assert.equals(v1_state, v1:read())
  end)

  it('rejects invalid references and resource names at the input boundary', function()
    local v1 = ready_connection('v1')
    local v2 = ready_connection('v2')

    assert.has_error(function()
      v1:observe({ id = 'ses-v1' })
    end, 'V1 observe requires the session location')
    assert.has_error(function()
      v2:observe({})
    end, 'observe requires a session id')

    local observation = v2:observe({ id = 'ses-v2' })
    assert.has_error(function()
      observation:watch({ 'messages', 'native-event' }, function() end)
    end, 'unsupported Observation resource: native-event')
  end)

  it('keeps independent watchers and releases after the last idempotent unsubscribe', function()
    local connection = ready_connection('v2')
    local observation = connection:observe({ id = 'ses-watch' })
    local unsubscribe_messages = observation:watch({ 'messages', 'messages' }, function() end)
    local unsubscribe_questions = observation:watch({ 'questions' }, function() end)

    unsubscribe_messages()
    assert.equals(observation, connection.observations['ses-watch'])
    unsubscribe_messages()
    assert.equals(observation, connection.observations['ses-watch'])

    unsubscribe_questions()
    assert.is_nil(connection.observations['ses-watch'])
  end)

  it('does not let a late old unsubscribe remove a replacement Observation', function()
    local connection = ready_connection('v2')
    local old = connection:observe({ id = 'ses-replaced' })
    local unsubscribe_old = old:watch({ 'session' }, function() end)

    connection.observations['ses-replaced'] = nil
    local replacement = connection:observe({ id = 'ses-replaced' })
    assert.not_equals(old, replacement)
    unsubscribe_old()
    assert.equals(replacement, connection.observations['ses-replaced'])
  end)

  it('invalidates all protocol Observations when the Connection closes', function()
    local connection = ready_connection('v2')
    local observation = connection:observe({ id = 'ses-close' })
    local unsubscribe = observation:watch({ 'messages' }, function() end)

    connection:close():wait()
    assert.same({}, connection.observations)
    assert.is_false(observation:_is_current())
    unsubscribe()
    assert.same({}, connection.observations)
  end)

  for _, protocol in ipairs({ 'v1', 'v2' }) do
    for _, outcome in ipairs({ 'resolve', 'reject', 'throw' }) do
      it('releases ' .. protocol .. ' actions after ' .. outcome .. ' without releasing a replacement', function()
        local connection = ready_connection(protocol)
        local ref = { id = 'ses-action', location = { directory = '/remote/project' } }
        local observation = connection:observe(ref)
        local pending = Promise.new()
        connection.operations = {
          interrupt = function(current, session_id, location)
            assert.equals(connection, current)
            assert.equals(ref.id, session_id)
            assert.same(protocol == 'v1' and ref.location or nil, location)
            assert.equals(1, observation._local_operations)
            if outcome == 'throw' then
              error('action failed', 0)
            end
            return pending
          end,
        }

        if outcome == 'throw' then
          assert.has_error(function()
            observation:interrupt()
          end, 'action failed')
          assert.is_nil(connection.observations[ref.id])
        else
          local result = observation:interrupt()
          assert.equals(observation, connection.observations[ref.id])
          connection.observations[ref.id] = nil
          local replacement = connection:observe(ref)
          if outcome == 'resolve' then
            pending:resolve(true)
            assert.is_true(result:wait())
          else
            pending:reject('action failed')
            assert.has_error(function()
              result:wait()
            end, 'action failed')
          end
          assert.equals(replacement, connection.observations[ref.id])
        end
        assert.equals(0, observation._local_operations)
        connection:close():wait()
      end)
    end
  end
end)
