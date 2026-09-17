local assert = require('luassert')
local observation_module = require('opencode.protocols.v1.observation')

local function fixture()
  local path = vim.fn.getcwd() .. '/tests/data/v1/observation-1.18.json'
  return vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
end

local function ready_connection()
  local connection = require('opencode.opencode_server').from_custom('http://v1.test')
  connection.protocol = 'v1'
  connection.server_identity = { version = '1.18.30' }
  connection.credential = { username = 'opencode' }
  return connection:mark_ready()
end

local function observation(session_id)
  return ready_connection():observe({ id = session_id, location = { directory = '/server/project' } })
end

local function content_by_id(entry, id)
  for _, content in ipairs(entry.content) do
    if content.id == id then
      return content
    end
  end
end

describe('V1 protocol Observation interpretation', function()
  it('validates a complete snapshot before replacing existing entries', function()
    local observed = observation(fixture().sessionID)
    local message = fixture().snapshot[2]
    observation_module.ingest_snapshot(observed, { message })
    local state = observed:read()
    local entry = state.entries_by_id['msg-assistant']
    local previous = vim.deepcopy(entry)
    local replacement = vim.deepcopy(message)
    replacement.info.cost = 99
    assert.has_error(function()
      observation_module.ingest_snapshot(observed, { replacement, vim.deepcopy(replacement) })
    end)
    assert.equals(entry, state.entries_by_id['msg-assistant'])
    assert.same(previous, entry)
    assert.same({ 'msg-assistant' }, state.entry_order)
    assert.has_error(function()
      observation_module.ingest_snapshot(observed, { replacement, { info = {} } })
    end)
    assert.same(previous, entry)
    assert.same({ 'msg-assistant' }, state.entry_order)
    observation_module.ingest_snapshot(observed, { replacement })
    assert.equals(entry, state.entries_by_id['msg-assistant'])
    assert.equals(99, entry.cost)
  end)

  it('projects fixed WithParts snapshots into ordered Entry and Content facts', function()
    local contract = fixture()
    local observed = observation(contract.sessionID)
    observation_module.ingest_snapshot(observed, contract.snapshot)
    local state = observed:read()

    assert.equals('3104c1428ec91f809e5ab86631300de41eb6952e', contract.sourceCommit)
    assert.same({ 'msg-user', 'msg-assistant', 'msg-error' }, state.entry_order)
    local user = state.entries_by_id['msg-user']
    local assistant = state.entries_by_id['msg-assistant']
    assert.equals('user', user.kind)
    assert.same({ providerID = 'provider', modelID = 'model', variant = 'high' }, user.model)
    assert.equals('assistant', assistant.kind)
    assert.equals('msg-user', assistant.parent_message_id)
    assert.equals(1700000000200, assistant.time.completed)
    assert.equals('stop', assistant.finish)
    assert.equals(0.25, assistant.cost)
    assert.same({ providerID = 'provider', modelID = 'model', variant = 'high' }, assistant.model)
    assert.equals(3, assistant.tokens.cache.read)

    assert.equals('text', content_by_id(user, 'prt-text').kind)
    assert.same({ started = 1700000000001, completed = 1700000000002 }, content_by_id(user, 'prt-text').time)
    assert.same({ started = 1700000000100, completed = 1700000000110 }, content_by_id(assistant, 'prt-reasoning').time)
    local file = content_by_id(user, 'prt-file')
    assert.equals('file:///server/main.lua', file.uri)
    assert.same({ kind = 'file', path = '/server/main.lua' }, file.source)
    assert.same({ text = '@main.lua', start_byte = 0, end_byte = 9 }, file.mention)
    assert.is_nil(file.source.type)
    assert.same({
      kind = 'symbol',
      path = '/server/lib.lua',
      name = 'run',
      range = { start = { line = 3, character = 2 }, ['end'] = { line = 3, character = 5 } },
    }, content_by_id(user, 'prt-symbol').source)
    assert.same({ kind = 'resource', uri = 'mcp://docs/readme' }, content_by_id(user, 'prt-resource').source)
    assert.same({ text = '@review', start_byte = 23, end_byte = 30 }, content_by_id(user, 'prt-agent').mention)
    assert.equals('compaction', content_by_id(user, 'prt-compaction').kind)
    assert.equals('msg-user', content_by_id(user, 'prt-compaction').boundary)
    assert.is_nil(content_by_id(user, 'prt-compaction').tail_start_id)
    assert.equals('subtask', content_by_id(user, 'prt-subtask').kind)
    assert.equals(503, content_by_id(assistant, 'prt-retry').error.status)
    assert.equals('snap-1', content_by_id(assistant, 'prt-snapshot').snapshot)
    assert.same({ 'main.lua' }, content_by_id(assistant, 'prt-patch').files)
    assert.equals('snap-start', content_by_id(assistant, 'prt-step-start').snapshot)
    assert.equals('stop', content_by_id(assistant, 'prt-step-finish').reason)
    assert.equals('MessageAbortedError', state.entries_by_id['msg-error'].error.type)
    assert.equals('interrupted', state.entries_by_id['msg-error'].error.message)
  end)

  it('keeps tool states, ordered results, and attachments in the tool Content', function()
    local contract = fixture()
    local observed = observation(contract.sessionID)
    observation_module.ingest_snapshot(observed, contract.snapshot)
    local assistant = observed:read().entries_by_id['msg-assistant']

    assert.equals('pending', content_by_id(assistant, 'prt-tool-pending').state)
    assert.equals('{"path":', content_by_id(assistant, 'prt-tool-pending').input_text)
    assert.equals('running', content_by_id(assistant, 'prt-tool-running').state)
    assert.equals(1700000000120, content_by_id(assistant, 'prt-tool-running').time.started)
    local completed = content_by_id(assistant, 'prt-tool-completed')
    assert.equals('completed', completed.state)
    assert.is_true(completed.executed)
    assert.same({ 'text', 'file' }, { completed.result[1].kind, completed.result[2].kind })
    assert.equals('contents', completed.result[1].text)
    assert.equals('image/png', completed.result[2].media_type)
    assert.equals(1700000000150, completed.time.compacted)
    local failed = content_by_id(assistant, 'prt-tool-error')
    assert.equals('error', failed.state)
    assert.equals('exit 1', failed.error.message)
  end)

  it('projects verified V1 tool fields and binds their session location', function()
    local contract = fixture()
    local message = vim.deepcopy(contract.snapshot[2])
    local identity = { sessionID = contract.sessionID, messageID = message.info.id, type = 'tool' }
    local function tool(part)
      return vim.tbl_extend('force', vim.deepcopy(identity), part)
    end
    message.parts = {
      tool({
        id = 'tool-bash',
        callID = 'call-bash',
        tool = 'bash',
        state = {
          status = 'running',
          input = { command = 'printf ok', description = 'print output' },
        },
      }),
      tool({
        id = 'tool-write',
        callID = 'call-write',
        tool = 'write',
        state = {
          status = 'completed',
          input = { filePath = '/server/project/new.lua', content = 'return true' },
          output = 'written',
          metadata = { diff = '@@ -0,0 +1 @@\n+return true' },
        },
      }),
      tool({
        id = 'tool-patch',
        callID = 'call-patch',
        tool = 'apply_patch',
        state = {
          status = 'completed',
          input = {},
          output = 'done',
          metadata = {
            files = {
              { filePath = '/server/project/a.lua', relativePath = 'a.lua', diff = 'diff-a' },
              { filePath = '/server/project/b.lua', patch = 'diff-b' },
            },
          },
        },
      }),
      tool({
        id = 'tool-task',
        callID = 'call-task',
        tool = 'task',
        state = {
          status = 'completed',
          input = { description = 'inspect code' },
          output = 'complete',
          metadata = { sessionId = 'ses-child' },
        },
      }),
      tool({
        id = 'tool-grep',
        callID = 'call-grep',
        tool = 'grep',
        state = {
          status = 'completed',
          input = {},
          output = 'matches',
          metadata = { matches = 3, truncated = false },
        },
      }),
      tool({
        id = 'tool-question',
        callID = 'call-question',
        tool = 'question',
        state = {
          status = 'completed',
          input = { questions = { { question = 'Proceed?', header = 'Choice' } } },
          output = 'answered',
          metadata = { answers = { { 'Yes' } } },
        },
      }),
      tool({
        id = 'tool-todo',
        callID = 'call-todo',
        tool = 'todowrite',
        state = {
          status = 'completed',
          input = { todos = { { content = 'Ship it', status = 'in_progress' } } },
          output = 'updated',
        },
      }),
    }
    local observed = observation(contract.sessionID)
    observation_module.ingest_snapshot(observed, { message })
    local entry = observed:read().entries_by_id[message.info.id]
    local location = { directory = '/server/project' }

    local bash = content_by_id(entry, 'tool-bash')
    assert.equals('printf ok', bash.command)
    assert.equals('print output', bash.description)
    local write = content_by_id(entry, 'tool-write')
    assert.same({ path = '/server/project/new.lua', location = location, content = 'return true' }, write.target)
    assert.same(
      { path = '/server/project/new.lua', location = location, diff = '@@ -0,0 +1 @@\n+return true' },
      write.changes[1]
    )
    local patch = content_by_id(entry, 'tool-patch')
    assert.same({ path = 'a.lua', location = location, diff = 'diff-a' }, patch.changes[1])
    assert.same({ path = '/server/project/b.lua', location = location, diff = 'diff-b' }, patch.changes[2])
    assert.same({ id = 'ses-child', location = location }, content_by_id(entry, 'tool-task').child_session)
    assert.same({ count = 3, truncated = false }, content_by_id(entry, 'tool-grep').search)
    assert.same(
      { question = 'Proceed?', header = 'Choice', values = { 'Yes' } },
      content_by_id(entry, 'tool-question').answers[1]
    )
    assert.same({ text = 'Ship it', state = 'in_progress' }, content_by_id(entry, 'tool-todo').todos[1])
    assert.equals('current', observed:read().sync.messages.state)
  end)

  it('maps native UTF-16 mention ranges to frozen UTF-8 byte ranges', function()
    local contract = fixture()
    local message = {
      info = vim.deepcopy(contract.snapshot[1].info),
      parts = {
        {
          id = 'prt-prompt',
          sessionID = contract.sessionID,
          messageID = 'msg-user',
          type = 'text',
          text = '中😀@file @review',
        },
        {
          id = 'prt-synthetic',
          sessionID = contract.sessionID,
          messageID = 'msg-user',
          type = 'text',
          text = 'synthetic text is longer than the prompt',
          synthetic = true,
        },
        {
          id = 'prt-file-utf16',
          sessionID = contract.sessionID,
          messageID = 'msg-user',
          type = 'file',
          mime = 'text/plain',
          url = 'file:///server/file',
          source = {
            type = 'file',
            path = '/server/file',
            text = { value = '@file', start = 3, ['end'] = 8 },
          },
        },
        {
          id = 'prt-agent-utf16',
          sessionID = contract.sessionID,
          messageID = 'msg-user',
          type = 'agent',
          name = 'review',
          source = { value = '@review', start = 9, ['end'] = 16 },
        },
      },
    }
    local observed = observation(contract.sessionID)
    observation_module.ingest_snapshot(observed, { message })
    local entry = observed:read().entries_by_id['msg-user']

    assert.same({ text = '@file', start_byte = 7, end_byte = 12 }, content_by_id(entry, 'prt-file-utf16').mention)
    assert.same({ text = '@review', start_byte = 13, end_byte = 20 }, content_by_id(entry, 'prt-agent-utf16').mention)
    assert.equals('current', observed:read().sync.messages.state)

    local invalid = vim.deepcopy(message)
    invalid.parts[3].source.text.start = 2
    observation_module.ingest_snapshot(observed, { invalid })
    assert.is_nil(content_by_id(observed:read().entries_by_id['msg-user'], 'prt-file-utf16').mention)
    assert.equals('protocol_contract', observed:read().sync.messages.error.kind)
    assert.matches('does not identify a prompt range', observed:read().sync.messages.error.message)

    invalid = vim.deepcopy(message)
    invalid.parts[3].source.text.value = '@other'
    observation_module.ingest_snapshot(observed, { invalid })
    assert.is_nil(content_by_id(observed:read().entries_by_id['msg-user'], 'prt-file-utf16').mention)
    assert.matches('does not identify a prompt range', observed:read().sync.messages.error.message)

    invalid.parts[1].synthetic = true
    observation_module.ingest_snapshot(observed, { invalid })
    assert.is_nil(content_by_id(observed:read().entries_by_id['msg-user'], 'prt-file-utf16').mention)
    assert.matches('has no prompt text', observed:read().sync.messages.error.message)
  end)

  it('decodes only proven editor context and diagnoses malformed source as ordinary text', function()
    local contract = fixture()
    local observed = observation(contract.sessionID)
    observation_module.ingest_snapshot(observed, contract.snapshot)
    local user = observed:read().entries_by_id['msg-user']
    local selection = content_by_id(user, 'prt-selection')
    local diagnostics = content_by_id(user, 'prt-diagnostics')
    local malformed = content_by_id(user, 'prt-invalid-context')

    assert.equals('editor_context', selection.kind)
    assert.same({ kind = 'selection', file_name = 'main.lua', range = '8-9' }, selection.source)
    assert.equals('return value', selection.text)
    assert.equals('editor_context', diagnostics.kind)
    assert.same({ message = 'bad value', severity = 2, position = 'l8:c3' }, diagnostics.diagnostics[1])
    assert.equals('text', malformed.kind)
    assert.equals('not-json', malformed.text)
    assert.equals('error', observed:read().sync.messages.state)
    assert.matches('invalid selection editor context JSON', observed:read().sync.messages.error.message)
  end)

  it('applies native message and part events in order and removes exact identities', function()
    local contract = fixture()
    local observed = observation(contract.sessionID)

    assert.is_true(observation_module.ingest_event(observed, contract.events.message))
    assert.is_true(observation_module.ingest_event(observed, contract.events.part))
    assert.is_true(observation_module.ingest_event(observed, contract.events.delta))
    assert.equals('AB', content_by_id(observed:read().entries_by_id['msg-live'], 'prt-live').text)

    local message_update = vim.deepcopy(contract.events.message)
    message_update.payload.properties.info.time.completed = 1700000000450
    message_update.payload.properties.info.finish = 'stop'
    assert.is_true(observation_module.ingest_event(observed, message_update))
    assert.equals('AB', content_by_id(observed:read().entries_by_id['msg-live'], 'prt-live').text)
    assert.equals('stop', observed:read().entries_by_id['msg-live'].finish)

    assert.is_true(observation_module.ingest_event(observed, contract.events.removePart))
    assert.same({}, observed:read().entries_by_id['msg-live'].content)
    assert.is_true(observation_module.ingest_event(observed, contract.events.removeMessage))
    assert.is_nil(observed:read().entries_by_id['msg-live'])
    assert.same({}, observed:read().entry_order)
  end)

  it('keeps usage when a later message update omits cost and tokens', function()
    local contract = fixture()
    local observed = observation(contract.sessionID)
    observation_module.ingest_snapshot(observed, { contract.snapshot[2] })

    local partial = {
      directory = '/server/project',
      payload = {
        type = 'message.updated',
        properties = {
          sessionID = contract.sessionID,
          info = vim.deepcopy(contract.snapshot[2].info),
        },
      },
    }
    partial.payload.properties.info.cost = nil
    partial.payload.properties.info.tokens = nil

    assert.is_true(observation_module.ingest_event(observed, partial))
    local assistant = observed:read().entries_by_id['msg-assistant']
    assert.equals(0.25, assistant.cost)
    assert.equals(3, assistant.tokens.cache.read)

    local partial_snapshot = vim.deepcopy(contract.snapshot[2])
    partial_snapshot.info.cost = nil
    partial_snapshot.info.tokens = nil
    observation_module.ingest_snapshot(observed, { partial_snapshot })
    assistant = observed:read().entries_by_id['msg-assistant']
    assert.equals(0.25, assistant.cost)
    assert.equals(3, assistant.tokens.cache.read)
  end)

  it('resolves file and agent mentions when native parts arrive before the prompt text', function()
    local contract = fixture()
    local observed = observation(contract.sessionID)
    assert.is_true(observation_module.ingest_event(observed, contract.events.message))

    local function part_event(part)
      return {
        directory = '/server/project',
        payload = {
          type = 'message.part.updated',
          properties = { sessionID = contract.sessionID, part = part },
        },
      }
    end

    local identity = { sessionID = contract.sessionID, messageID = 'msg-live' }
    local file = vim.tbl_extend('force', identity, {
      id = 'prt-file-first',
      type = 'file',
      mime = 'text/plain',
      url = 'file:///server/file',
      source = {
        type = 'file',
        path = '/server/file',
        text = { value = '@file', start = 3, ['end'] = 8 },
      },
    })
    local agent = vim.tbl_extend('force', identity, {
      id = 'prt-agent-first',
      type = 'agent',
      name = 'review',
      source = { value = '@review', start = 9, ['end'] = 16 },
    })
    assert.is_true(observation_module.ingest_event(observed, part_event(file)))
    assert.is_true(observation_module.ingest_event(observed, part_event(agent)))
    local entry = observed:read().entries_by_id['msg-live']
    assert.is_nil(content_by_id(entry, 'prt-file-first').mention)
    assert.is_nil(content_by_id(entry, 'prt-agent-first').mention)
    assert.is_not_nil(observed._v1_unresolved_mentions['msg-live']['prt-file-first'])
    assert.is_not_nil(observed._v1_unresolved_mentions['msg-live']['prt-agent-first'])

    local prompt = vim.tbl_extend('force', identity, {
      id = 'prt-prompt-last',
      type = 'text',
      text = '中😀@file @review',
    })
    assert.is_true(observation_module.ingest_event(observed, part_event(prompt)))
    assert.same({ text = '@file', start_byte = 7, end_byte = 12 }, content_by_id(entry, 'prt-file-first').mention)
    assert.same({ text = '@review', start_byte = 13, end_byte = 20 }, content_by_id(entry, 'prt-agent-first').mention)
    assert.is_nil(observed._v1_unresolved_mentions['msg-live'])

    assert.is_true(observation_module.ingest_event(observed, contract.events.removeMessage))
    assert.is_nil(observed._v1_unresolved_mentions['msg-live'])

    assert.is_true(observation_module.ingest_event(observed, contract.events.message))
    assert.is_true(observation_module.ingest_event(observed, part_event(file)))
    local remove_file = {
      directory = '/server/project',
      payload = {
        type = 'message.part.removed',
        properties = { sessionID = contract.sessionID, messageID = 'msg-live', partID = 'prt-file-first' },
      },
    }
    assert.is_true(observation_module.ingest_event(observed, remove_file))
    assert.is_nil(observed._v1_unresolved_mentions['msg-live'])

    assert.is_true(observation_module.ingest_event(observed, part_event(agent)))
    assert.is_not_nil(observed._v1_unresolved_mentions['msg-live'])
    observation_module.ingest_snapshot(observed, contract.snapshot)
    assert.same({}, observed._v1_unresolved_mentions)

    assert.is_true(observation_module.ingest_event(observed, contract.events.message))
    assert.is_true(observation_module.ingest_event(observed, part_event(file)))
    observed._connection:close()
    assert.same({}, observed._v1_unresolved_mentions)
  end)

  it('ignores another session and records missing identities without partial writes', function()
    local contract = fixture()
    local observed = observation(contract.sessionID)

    assert.is_false(observation_module.ingest_event(observed, contract.events.foreign))
    assert.is_nil(observed:read().entries_by_id['msg-foreign'])
    assert.is_false(observation_module.ingest_event(observed, contract.events.foreignDirectory))
    assert.is_nil(observed:read().entries_by_id['msg-live'])
    local missing_directory = vim.deepcopy(contract.events.message)
    missing_directory.directory = nil
    assert.is_false(observation_module.ingest_event(observed, missing_directory))
    assert.matches('missing directory', observed:read().sync.messages.error.message)
    assert.is_false(observation_module.ingest_event(observed, contract.events.missingID))
    assert.equals('error', observed:read().sync.messages.state)
    assert.matches('missing part identity', observed:read().sync.messages.error.message)

    local invalid_snapshot = vim.deepcopy(contract.snapshot)
    invalid_snapshot[2].info.sessionID = 'ses-other'
    local before = vim.deepcopy(observed:read().entries_by_id)
    assert.has_error(function()
      observation_module.ingest_snapshot(observed, invalid_snapshot)
    end, 'V1 observation: part belongs to another message')
    assert.same(before, observed:read().entries_by_id)
  end)
end)
