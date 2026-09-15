local assert = require('luassert')
local Promise = require('opencode.promise')

local function connection_with(operations)
  local connection = require('opencode.opencode_server').from_custom('http://v1.test')
  connection.protocol = 'v1'
  connection.server_identity = { version = '1.18.30' }
  connection.credential = { username = 'opencode' }
  connection:mark_ready()
  connection.operations = operations
  return connection
end

local function deferred()
  return Promise.new()
end

local function resolved(value)
  return Promise.new():resolve(value)
end

local function runtime()
  local state = {
    streams = {},
    messages = {},
    permissions = {},
    sessions = {},
    children = {},
    statuses = {},
    questions = {},
    submits = {},
    actions = {},
  }
  local operations = {}

  function operations.subscribe_events(connection, on_chunk, on_disconnect)
    local stream = { on_chunk = on_chunk, on_disconnect = on_disconnect, shutdown_count = 0 }
    function stream:shutdown()
      self.shutdown_count = self.shutdown_count + 1
    end
    state.streams[#state.streams + 1] = stream
    connection:set_stream(stream)
    return stream
  end

  function operations.list_messages(_, session_id, _, limit, before)
    local request = deferred()
    request.limit = limit
    request.before = before
    state.messages[session_id] = state.messages[session_id] or {}
    state.messages[session_id][#state.messages[session_id] + 1] = request
    return request
  end

  function operations.list_permissions()
    local request = deferred()
    state.permissions[#state.permissions + 1] = request
    return request
  end

  function operations.get_session(_, session_id)
    local request = deferred()
    state.sessions[session_id] = state.sessions[session_id] or {}
    state.sessions[session_id][#state.sessions[session_id] + 1] = request
    return request
  end

  function operations.list_children(_, session_id)
    local request = deferred()
    state.children[session_id] = state.children[session_id] or {}
    state.children[session_id][#state.children[session_id] + 1] = request
    return request
  end

  function operations.list_session_status()
    local request = deferred()
    state.statuses[#state.statuses + 1] = request
    return request
  end

  function operations.list_questions()
    local request = deferred()
    state.questions[#state.questions + 1] = request
    return request
  end

  function operations.submit(_, session_id, location, input)
    local request = deferred()
    state.submits[#state.submits + 1] = {
      session_id = session_id,
      location = location,
      input = input,
      request = request,
    }
    return request
  end

  function operations.interrupt(_, session_id, location)
    local request = deferred()
    state.actions[#state.actions + 1] = {
      kind = 'interrupt',
      session_id = session_id,
      location = location,
      request = request,
    }
    return request
  end

  function operations.reply_permission(_, request_id, location, answer)
    state.actions[#state.actions + 1] = {
      kind = 'permission',
      request_id = request_id,
      location = location,
      answer = answer,
    }
    return resolved(true)
  end

  function operations.reply_question(_, request_id, location, answers)
    state.actions[#state.actions + 1] = {
      kind = 'question',
      request_id = request_id,
      location = location,
      answers = answers,
    }
    return resolved(true)
  end

  function operations.reject_question(_, request_id, location)
    state.actions[#state.actions + 1] = { kind = 'reject_question', request_id = request_id, location = location }
    return resolved(true)
  end

  return connection_with(operations), state
end

local function observe(connection, session_id)
  return connection:observe({ id = session_id, location = { directory = '/server/project' } })
end

local function response(session_id, id, parent_id, role, completed, finish, parts, err)
  return {
    info = {
      id = id,
      sessionID = session_id,
      role = role or 'assistant',
      parentID = parent_id,
      time = { created = 1700000000000, completed = completed },
      finish = finish,
      error = err,
    },
    parts = parts or {},
  }
end

local function emit(stream, directory, event_type, properties)
  stream.on_chunk('data: ' .. vim.json.encode({
    directory = directory,
    payload = { type = event_type, properties = properties },
  }) .. '\n\n')
end

local function history_message(session_id, message_id, parent_id, finish)
  return response(session_id, message_id, parent_id, 'assistant', 2, finish or 'stop')
end

describe('V1 protocol Observation runtime', function()
  it('shares one event stream across Observations and stops it after the last watcher', function()
    local connection, server = runtime()
    local first = observe(connection, 'ses-first')
    local second = observe(connection, 'ses-second')
    local unsubscribe_first = first:watch({ 'messages' }, function() end)
    local unsubscribe_first_again = first:watch({ 'messages', 'messages' }, function() end)
    local unsubscribe_second = second:watch({ 'messages' }, function() end)
    local unsubscribe_inbox = second:watch({ 'inbox' }, function() end)

    assert.equals(1, #server.streams)
    assert.equals(1, #server.messages['ses-first'])
    assert.equals(1, #server.messages['ses-second'])

    unsubscribe_first()
    unsubscribe_first_again()
    assert.equals(0, server.streams[1].shutdown_count)
    unsubscribe_second()
    assert.equals(1, server.streams[1].shutdown_count)
    assert.equals(second, connection.observations['ses-second'])
    unsubscribe_second()
    assert.equals(1, server.streams[1].shutdown_count)
    unsubscribe_inbox()
    assert.is_nil(connection.observations['ses-second'])
  end)

  it('projects V1 file events as one protocol-neutral file change fact', function()
    local connection, server = runtime()
    local observation = observe(connection, 'ses-files')
    local changes = 0
    local stop = observation:watch({ 'files' }, function()
      changes = changes + 1
    end)

    assert.equals('current', observation:read().sync.files.state)
    emit(server.streams[1], '/server/project', 'file.edited', { file = '/server/project/a.lua' })
    assert.equals(1, observation:read().files.revision)
    assert.same({ path = '/server/project/a.lua', event = 'change' }, observation:read().files.last)
    assert.is_true(changes >= 2)

    emit(server.streams[1], '/server/project', 'file.edited', {})
    assert.equals('error', observation:read().sync.files.state)
    assert.equals(1, observation:read().files.revision)
    stop()
  end)

  it('does not let unsupported inbox demand retain V1 stream or unresolved message state', function()
    local connection, server = runtime()
    local observation = observe(connection, 'ses-demand')
    local unsubscribe_inbox = observation:watch({ 'inbox' }, function() end)
    assert.equals(0, #server.streams)

    local unsubscribe_messages = observation:watch({ 'messages' }, function() end)
    assert.equals(1, #server.streams)
    emit(server.streams[1], '/server/project', 'message.updated', {
      sessionID = 'ses-demand',
      info = response('ses-demand', 'msg-demand', nil, 'user').info,
    })
    emit(server.streams[1], '/server/project', 'message.part.updated', {
      sessionID = 'ses-demand',
      part = {
        id = 'prt-demand-file',
        sessionID = 'ses-demand',
        messageID = 'msg-demand',
        type = 'file',
        mime = 'text/plain',
        url = 'file:///server/file',
        source = {
          type = 'file',
          path = '/server/file',
          text = { value = '@file', start = 0, ['end'] = 5 },
        },
      },
    })
    assert.is_not_nil(observation._v1_unresolved_mentions['msg-demand'])

    unsubscribe_messages()
    assert.equals(1, server.streams[1].shutdown_count)
    assert.same({}, observation._v1_unresolved_mentions)
    assert.equals(observation, connection.observations['ses-demand'])
    unsubscribe_inbox()
    assert.is_nil(connection.observations['ses-demand'])
  end)

  it('updates resource sync independently', function()
    local connection, server = runtime()
    local observation = observe(connection, 'ses-sync')
    local unsubscribe = observation:watch({ 'messages', 'permissions' }, function() end)

    assert.equals('loading', observation:read().sync.messages.state)
    assert.equals('loading', observation:read().sync.permissions.state)
    server.permissions[1]:resolve({})
    server.messages['ses-sync'][1]:reject('messages unavailable')
    assert.is_true(vim.wait(500, function()
      return observation:read().sync.permissions.state == 'current'
        and observation:read().sync.messages.state == 'error'
    end, 10))

    assert.equals('current', observation:read().sync.permissions.state)
    assert.equals('error', observation:read().sync.messages.state)
    assert.matches('messages unavailable', observation:read().sync.messages.error.message)
    unsubscribe()
  end)

  it('rejects a late finite read after the Observation has been replaced', function()
    local connection, server = runtime()
    local old = observe(connection, 'ses-replaced')
    local unsubscribe_old = old:watch({ 'messages' }, function() end)
    local old_request = server.messages['ses-replaced'][1]
    unsubscribe_old()

    local replacement = observe(connection, 'ses-replaced')
    local unsubscribe_replacement = replacement:watch({ 'messages' }, function() end)
    local replacement_request = server.messages['ses-replaced'][2]
    old_request:resolve({})
    assert.is_true(vim.wait(500, function()
      return old_request:is_resolved()
    end, 10))

    assert.equals('unread', old:read().sync.messages.state)
    assert.equals('loading', replacement:read().sync.messages.state)
    replacement_request:resolve({})
    assert.is_true(vim.wait(500, function()
      return replacement:read().sync.messages.state == 'current'
    end, 10))
    assert.equals('current', replacement:read().sync.messages.state)
    unsubscribe_replacement()
  end)

  it('stops an invalid stream and recovers watched resources on a replacement stream', function()
    local connection, server = runtime()
    local observation = observe(connection, 'ses-recover')
    local unsubscribe = observation:watch({ 'messages' }, function() end)
    local stale_request = server.messages['ses-recover'][1]

    server.streams[1].on_chunk('data: {invalid\n\n')
    assert.equals(1, server.streams[1].shutdown_count)
    assert.is_nil(connection._stream)
    assert.equals('error', observation:read().sync.messages.state)
    assert.matches('invalid V1 event JSON', observation:read().sync.messages.error.message)

    assert.is_true(vim.wait(500, function()
      return #server.streams == 2 and #server.messages['ses-recover'] == 2
    end, 10))
    assert.equals(server.streams[2], connection._stream)
    stale_request:resolve({})
    server.messages['ses-recover'][2]:resolve({})
    assert.is_true(vim.wait(500, function()
      return observation:read().sync.messages.state == 'current'
    end, 10))

    unsubscribe()
    assert.equals(1, server.streams[2].shutdown_count)
  end)

  it('cancels queued stream recovery when the Connection closes with watchers', function()
    local connection, server = runtime()
    local observation = observe(connection, 'ses-close')
    observation:watch({ 'messages' }, function() end)
    server.streams[1].on_disconnect('network lost')

    assert.is_not_nil(connection._observation_retry)
    connection:close()
    assert.is_nil(connection._observation_retry)
    assert.is_nil(connection._observation_stream)
    assert.is_nil(connection._stream)
    assert.is_false(observation:_is_current())
    assert.same({}, connection.observations)
    vim.wait(200)
    assert.equals(1, #server.streams)
  end)

  it('routes native resources by directory and session and converges after event-before-snapshot', function()
    local connection, server = runtime()
    local observation = observe(connection, 'ses-events')
    local changes = 0
    local unsubscribe = observation:watch(
      { 'session', 'children', 'execution', 'permissions', 'questions' },
      function(changed)
        assert.equals(observation, changed)
        changes = changes + 1
      end
    )
    local session = {
      id = 'ses-events',
      slug = 'events',
      title = 'Updated session',
      directory = '/server/project',
      projectID = 'project-1',
      version = '1.18.30',
      time = { created = 1, updated = 2 },
    }
    local child = {
      id = 'ses-child',
      slug = 'child',
      title = 'Child',
      parentID = 'ses-events',
      directory = '/server/project',
      projectID = 'project-1',
      version = '1.18.30',
      time = { created = 2, updated = 2 },
    }
    local permission = {
      id = 'per-1',
      sessionID = 'ses-events',
      permission = 'edit',
      patterns = { 'src/*' },
      metadata = {},
      always = { 'src/*' },
    }
    local question = {
      id = 'que-1',
      sessionID = 'ses-events',
      questions = {
        {
          question = 'Proceed?',
          header = 'Confirm',
          options = { { label = 'Yes', description = 'Continue' } },
        },
      },
    }

    emit(server.streams[1], '/foreign', 'session.updated', { sessionID = 'ses-events', info = session })
    assert.equals('loading', observation:read().sync.session.state)
    emit(server.streams[1], '/server/project', 'session.updated', { sessionID = 'ses-events', info = session })
    emit(server.streams[1], '/server/project', 'session.created', { sessionID = 'ses-child', info = child })
    emit(server.streams[1], '/server/project', 'session.status', {
      sessionID = 'ses-events',
      status = { type = 'busy' },
    })
    emit(server.streams[1], '/server/project', 'permission.asked', permission)
    emit(server.streams[1], '/server/project', 'question.asked', question)
    emit(server.streams[1], '/server/project', 'permission.replied', {
      sessionID = 'ses-events',
      requestID = 'per-1',
      reply = 'once',
    })
    emit(server.streams[1], '/server/project', 'question.rejected', {
      sessionID = 'ses-events',
      requestID = 'que-1',
    })

    assert.equals('Updated session', observation:read().session.title)
    assert.equals('ses-child', observation:read().children.order[1])
    assert.equals('running', observation:read().execution.activity)
    assert.equals('answered', observation:read().permission_requests_by_id['per-1'].status)
    assert.equals('rejected', observation:read().question_requests_by_id['que-1'].status)
    assert.is_true(changes >= 7)

    server.sessions['ses-events'][1]:resolve(session)
    server.children['ses-events'][1]:resolve({ child })
    server.statuses[1]:resolve({ ['ses-events'] = { type = 'busy' } })
    server.permissions[1]:resolve({ permission })
    server.questions[1]:resolve({ question })
    assert.is_true(vim.wait(500, function()
      return #server.sessions['ses-events'] == 2
        and #server.children['ses-events'] == 2
        and #server.statuses == 2
        and #server.permissions == 2
        and #server.questions == 2
    end, 10))
    server.sessions['ses-events'][2]:resolve(session)
    server.children['ses-events'][2]:resolve({ child })
    server.statuses[2]:resolve({ ['ses-events'] = { type = 'busy' } })
    server.permissions[2]:resolve({ permission })
    server.questions[2]:resolve({ question })
    assert.is_true(vim.wait(500, function()
      for _, resource in ipairs({ 'session', 'children', 'execution', 'permissions', 'questions' }) do
        if observation:read().sync[resource].state ~= 'current' then
          return false
        end
      end
      return true
    end, 10))
    assert.equals('answered', observation:read().permission_requests_by_id['per-1'].status)
    assert.equals('rejected', observation:read().question_requests_by_id['que-1'].status)
    unsubscribe()
  end)

  it('records missing native resource identities without changing another resource', function()
    local connection, server = runtime()
    local observation = observe(connection, 'ses-missing')
    local unsubscribe = observation:watch({ 'execution', 'questions' }, function() end)
    emit(server.streams[1], '/server/project', 'session.status', { status = { type = 'busy' } })

    assert.equals('error', observation:read().sync.execution.state)
    assert.matches('missing sessionID', observation:read().sync.execution.error.message)
    assert.equals('loading', observation:read().sync.questions.state)
    unsubscribe()
  end)

  it('merges bounded older history without overwriting a newer online message', function()
    local connection, server = runtime()
    local observation = observe(connection, 'ses-history')
    local unsubscribe = observation:watch({ 'messages' }, function() end)
    local initial = {}
    for index = 1, 50 do
      initial[index] = history_message('ses-history', string.format('msg-%03d', index), 'msg-input', 'stop')
    end
    server.messages['ses-history'][1]:resolve(initial)
    assert.is_true(vim.wait(500, function()
      return observation:read().sync.messages.state == 'current'
    end, 10))

    local loading = observation:load_older()
    assert.equals(100, server.messages['ses-history'][2].limit)
    assert.is_nil(server.messages['ses-history'][2].before)
    local online = history_message('ses-history', 'msg-001', 'msg-input', 'online-finish')
    emit(server.streams[1], '/server/project', 'message.updated', {
      sessionID = 'ses-history',
      info = online.info,
    })
    local older = {
      history_message('ses-history', 'msg-old-a', 'msg-input', 'stop'),
      history_message('ses-history', 'msg-old-b', 'msg-input', 'stop'),
    }
    for index = 1, 50 do
      older[#older + 1] = history_message(
        'ses-history',
        string.format('msg-%03d', index),
        'msg-input',
        index == 1 and 'stale-finish' or 'stop'
      )
    end
    server.messages['ses-history'][2]:resolve(older)
    assert.is_true(vim.wait(500, function()
      return #server.messages['ses-history'] == 3
    end, 10))
    assert.is_nil(observation:read().entries_by_id['msg-old-a'])
    assert.is_nil(server.messages['ses-history'][3].before)
    server.messages['ses-history'][3]:resolve(older)
    loading:wait()

    assert.same({ 'msg-old-a', 'msg-old-b', 'msg-001' }, {
      observation:read().entry_order[1],
      observation:read().entry_order[2],
      observation:read().entry_order[3],
    })
    assert.equals('online-finish', observation:read().entries_by_id['msg-001'].finish)
    assert.equals('current', observation:read().sync.messages.state)
    assert.is_true(observation._v1_history_complete)
    unsubscribe()
  end)

  it('rejects a duplicate older page atomically', function()
    local connection, server = runtime()
    local observation = observe(connection, 'ses-history-invalid')
    local loading = observation:load_older()
    assert.equals(100, server.messages['ses-history-invalid'][1].limit)
    assert.is_nil(server.messages['ses-history-invalid'][1].before)
    local duplicate = history_message('ses-history-invalid', 'msg-duplicate', 'msg-input', 'stop')
    server.messages['ses-history-invalid'][1]:resolve({ duplicate, vim.deepcopy(duplicate) })

    assert.has_error(function()
      loading:wait()
    end, 'V1 observation: older messages contain a duplicate message')
    assert.same({}, observation:read().entries_by_id)
    assert.same({}, observation:read().entry_order)
  end)

  it('returns reply only for the generated input parent and a terminal V1 response', function()
    local connection, server = runtime()
    local observation = observe(connection, 'ses-submit')
    local first = observation:submit({ text = 'A', context = {}, files = {}, agents = {} })
    local second = observation:submit({ text = 'B', context = {}, files = {}, agents = {} })
    local first_id = server.submits[1].input.messageID
    local second_id = server.submits[2].input.messageID
    local shared = response('ses-submit', 'msg-reply', second_id, 'assistant', 1700000000100, 'stop')

    server.submits[1].request:resolve(vim.deepcopy(shared))
    server.submits[2].request:resolve(vim.deepcopy(shared))
    local first_result = first:wait()
    local second_result = second:wait()

    assert.equals('accepted', first_result.kind)
    assert.equals(first_id, first_result.input.id)
    assert.equals('reply', second_result.kind)
    assert.equals(second_id, second_result.input_id)
    assert.equals(observation:read().entries_by_id['msg-reply'], second_result.message)
    assert.equals('/server/project', server.submits[1].location.directory)
    assert.same({ type = 'text', text = 'A' }, server.submits[1].input.parts[1])
    assert.not_equals(first_id, second_id)
    assert.is_nil(connection.observations['ses-submit'])
  end)

  it('encodes frozen submit content and explicit V1 send options before the operation', function()
    local connection, server = runtime()
    local observation = observe(connection, 'ses-wire')
    local result = observation:submit({
      text = '中😀@review @file',
      context = {
        { text = 'buffer text', source = { kind = 'buffer', file_name = 'draft.lua' } },
      },
      files = {
        { bytes = 'raw', media_type = 'text/plain', name = 'note.txt' },
        {
          server_uri = 'file:///server/project/main.lua',
          media_type = 'text/plain',
          name = 'main.lua',
          mention = { start_byte = 15, end_byte = 20 },
        },
      },
      agents = { { name = 'review', mention = { start_byte = 7, end_byte = 14 } } },
      model = { providerID = 'provider', modelID = 'model' },
      agent = 'build',
      variant = 'high',
      system = 'be precise',
    })
    local input = server.submits[1].input

    assert.same({ providerID = 'provider', modelID = 'model' }, input.model)
    assert.equals('build', input.agent)
    assert.equals('high', input.variant)
    assert.equals('be precise', input.system)
    assert.same({ context_type = 'file-content', filename = 'draft.lua' }, input.parts[1].metadata)
    assert.equals('data:text/plain;base64,' .. vim.base64.encode('raw'), input.parts[2].url)
    assert.same({
      type = 'file',
      path = '/server/project/main.lua',
      text = { value = '@file', start = 11, ['end'] = 16 },
    }, input.parts[3].source)
    assert.same({ value = '@review', start = 3, ['end'] = 10 }, input.parts[4].source)
    assert.same({ type = 'text', text = '中😀@review @file' }, input.parts[5])

    server.submits[1].request:resolve(response('ses-wire', 'msg-user', input.messageID, 'user', 2, 'stop'))
    assert.equals('accepted', result:wait().kind)

    assert.has_error(function()
      observe(connection, 'ses-wire-invalid'):submit({
        text = '@file',
        context = {},
        files = {
          {
            bytes = 'raw',
            media_type = 'text/plain',
            mention = { start_byte = 0, end_byte = 5 },
          },
        },
        agents = {},
      })
    end, 'V1 observation: V1 cannot attach a mention to bytes without a server file identity')
    assert.equals(1, #server.submits)

    assert.has_error(function()
      observe(connection, 'ses-wire-half-codepoint'):submit({
        text = '中😀@review',
        context = {},
        files = {},
        agents = { { name = 'review', mention = { start_byte = 4, end_byte = 14 } } },
      })
    end, 'V1 observation: input mention must use UTF-8 codepoint boundaries')
    assert.equals(1, #server.submits)
  end)

  it('keeps accepted for user, wrong-parent, incomplete, and continuing-tool responses', function()
    local cases = {
      function(input_id)
        return response('ses-accepted', 'msg-user', input_id, 'user', 1700000000100, 'stop')
      end,
      function()
        return response('ses-accepted', 'msg-wrong-parent', 'msg-other', 'assistant', 1700000000100, 'stop')
      end,
      function(input_id)
        return response('ses-accepted', 'msg-incomplete', input_id, 'assistant', nil, 'stop')
      end,
      function(input_id)
        return response('ses-accepted', 'msg-tool-calls', input_id, 'assistant', 1700000000100, 'tool-calls')
      end,
      function(input_id)
        return response('ses-accepted', 'msg-tool-loop', input_id, 'assistant', 1700000000100, 'stop', {
          {
            id = 'prt-tool',
            sessionID = 'ses-accepted',
            messageID = 'msg-tool-loop',
            type = 'tool',
            callID = 'call-1',
            tool = 'read',
            state = { status = 'completed', input = {}, output = 'done' },
          },
        })
      end,
    }

    for _, make_response in ipairs(cases) do
      local connection, server = runtime()
      local observation = observe(connection, 'ses-accepted')
      local result = observation:submit({ text = 'hello', context = {}, files = {}, agents = {} })
      local input_id = server.submits[1].input.messageID
      server.submits[1].request:resolve(make_response(input_id))
      assert.equals('accepted', result:wait().kind)
    end
  end)

  it('accepts native tool-loop exceptions and terminal assistant errors as replies', function()
    local connection, server = runtime()
    local observation = observe(connection, 'ses-terminal')
    local unsubscribe = observation:watch({ 'inbox' }, function() end)
    local provider = observation:submit({ text = 'provider', context = {}, files = {}, agents = {} })
    local provider_id = server.submits[1].input.messageID
    server.submits[1].request:resolve(response('ses-terminal', 'msg-provider', provider_id, 'assistant', 2, 'stop', {
      {
        id = 'prt-provider',
        sessionID = 'ses-terminal',
        messageID = 'msg-provider',
        type = 'tool',
        callID = 'call-provider',
        tool = 'read',
        metadata = { providerExecuted = true },
        state = { status = 'completed', input = {}, output = 'done' },
      },
    }))
    assert.equals('reply', provider:wait().kind)

    local interrupted = observation:submit({ text = 'interrupt', context = {}, files = {}, agents = {} })
    local interrupted_id = server.submits[2].input.messageID
    server.submits[2].request:resolve(
      response('ses-terminal', 'msg-interrupt', interrupted_id, 'assistant', 3, 'stop', {
        {
          id = 'prt-interrupt',
          sessionID = 'ses-terminal',
          messageID = 'msg-interrupt',
          type = 'tool',
          callID = 'call-interrupt',
          tool = 'read',
          state = { status = 'error', input = {}, error = 'interrupted', metadata = { interrupted = true } },
        },
      })
    )
    assert.equals('reply', interrupted:wait().kind)

    local failed = observation:submit({ text = 'fail', context = {}, files = {}, agents = {} })
    local failed_id = server.submits[3].input.messageID
    server.submits[3].request:resolve(response('ses-terminal', 'msg-failed', failed_id, 'assistant', 4, nil, {}, {
      name = 'MessageAbortedError',
      data = { message = 'interrupted' },
    }))
    assert.equals('reply', failed:wait().kind)
    unsubscribe()
  end)

  it('rejects cross-session and HTTP failures without writing or returning accepted', function()
    local connection, server = runtime()
    local observation = observe(connection, 'ses-errors')
    local foreign = observation:submit({ text = 'foreign', context = {}, files = {}, agents = {} })
    local foreign_id = server.submits[1].input.messageID
    server.submits[1].request:resolve(response('ses-other', 'msg-foreign', foreign_id, 'assistant', 2, 'stop'))
    assert.has_error(function()
      foreign:wait()
    end, 'V1 observation: submit response belongs to another session')
    assert.is_nil(observation:read().entries_by_id['msg-foreign'])

    connection.observations['ses-errors'] = observation
    local rejected = observation:submit({ text = 'reject', context = {}, files = {}, agents = {} })
    server.submits[2].request:reject('HTTP 500')
    assert.has_error(function()
      rejected:wait()
    end, 'HTTP 500')
  end)

  it('keeps the Observation alive until a local submit settles after its watcher leaves', function()
    local connection, server = runtime()
    local observation = observe(connection, 'ses-lifetime')
    local unsubscribe = observation:watch({ 'messages' }, function() end)
    local result = observation:submit({ text = 'hello', context = {}, files = {}, agents = {} })
    local input_id = server.submits[1].input.messageID
    unsubscribe()
    assert.equals(observation, connection.observations['ses-lifetime'])

    server.submits[1].request:resolve(response('ses-lifetime', 'msg-reply', input_id, 'assistant', 2, 'stop'))
    assert.equals('reply', result:wait().kind)
    assert.is_nil(connection.observations['ses-lifetime'])
  end)

  it('encodes V1 interaction replies through operations without fabricating local completion', function()
    local connection, server = runtime()
    local observation = observe(connection, 'ses-actions')
    local unsubscribe = observation:watch({ 'permissions', 'questions' }, function() end)
    local permission = {
      id = 'per-action',
      sessionID = 'ses-actions',
      permission = 'edit',
      patterns = { 'src/*' },
      metadata = {},
      always = {},
    }
    local question = {
      id = 'que-action',
      sessionID = 'ses-actions',
      questions = {
        {
          question = 'Targets?',
          header = 'Select',
          multiple = true,
          options = {
            { label = 'A', description = 'Target A' },
            { label = 'B', description = 'Target B' },
          },
        },
      },
    }
    local rejected_question = vim.deepcopy(question)
    rejected_question.id = 'que-reject'
    emit(server.streams[1], '/server/project', 'permission.asked', permission)
    emit(server.streams[1], '/server/project', 'question.asked', question)
    emit(server.streams[1], '/server/project', 'question.asked', rejected_question)

    assert.has_error(function()
      observation:reply_permission('per-missing', { choice = 'once' })
    end, 'V1 observation: permission request is not pending')
    assert.has_error(function()
      observation:reply_permission('per-action', { choice = 'maybe' })
    end, 'V1 observation: invalid permission answer')
    assert.has_error(function()
      observation:reply_question('que-action', {})
    end, 'V1 observation: question answer 1 must be a string list')
    assert.has_error(function()
      observation:reject_question('que-missing')
    end, 'V1 observation: question request is not pending')
    assert.same({}, server.actions)

    local interrupted = observation:interrupt()
    server.actions[1].request:resolve(true)
    assert.is_true(interrupted:wait())
    assert.is_true(observation:reply_permission('per-action', { choice = 'once' }):wait())
    assert.is_true(observation:reply_question('que-action', { ['1'] = { 'A', 'B' } }):wait())
    assert.is_true(observation:reject_question('que-reject'):wait())
    assert.same({ reply = 'once' }, server.actions[2].answer)
    assert.same({ { 'A', 'B' } }, server.actions[3].answers)
    assert.equals('pending', observation:read().permission_requests_by_id['per-action'].status)
    assert.equals('pending', observation:read().question_requests_by_id['que-action'].status)
    assert.equals('pending', observation:read().question_requests_by_id['que-reject'].status)
    unsubscribe()

    local lifetime = observe(connection, 'ses-action-lifetime')
    local stop_lifetime = lifetime:watch({ 'inbox' }, function() end)
    local interrupt_lifetime = lifetime:interrupt()
    stop_lifetime()
    assert.equals(lifetime, connection.observations['ses-action-lifetime'])
    server.actions[5].request:resolve(true)
    assert.is_true(interrupt_lifetime:wait())
    assert.is_nil(connection.observations['ses-action-lifetime'])
  end)
end)
