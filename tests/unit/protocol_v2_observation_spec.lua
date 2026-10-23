local assert = require('luassert')
local observation_module = require('opencode.protocols.v2.observation')

local function observation(session_id)
  local connection = require('opencode.opencode_server').from_custom('http://v2.test')
  connection.protocol = 'v2'
  connection.server_identity = { version = '2.0.1' }
  connection.credential = { username = 'opencode' }
  connection:mark_ready()
  return connection:observe({ id = session_id })
end

local function assistant(id)
  return {
    id = id,
    type = 'assistant',
    agent = 'build',
    model = { providerID = 'provider', id = 'model', variant = 'high' },
    time = { created = 200, streamed = 220, completed = 240 },
    finish = 'stop',
    cost = 0.25,
    tokens = { input = 10, output = 5, reasoning = 2, cache = { read = 3, write = 1 } },
    snapshot = { start = 'snap-start', ['end'] = 'snap-end', files = { 'main.lua' } },
    content = {
      { type = 'reasoning', text = 'think', time = { created = 201, completed = 205 } },
      { type = 'text', text = 'answer' },
      {
        type = 'tool',
        id = 'tool-1',
        name = 'patch',
        executed = true,
        time = { created = 206, ran = 207, completed = 210 },
        state = {
          status = 'completed',
          input = { path = 'main.lua' },
          metadata = {
            arbitrary = 'must-not-leak',
            files = {
              {
                file = 'main.lua',
                patch = '@@ -9,1 +9,1 @@\n-old\n+new',
              },
            },
          },
          content = {
            { type = 'text', text = 'created' },
            { type = 'file', uri = 'file:///tmp/report.png', mime = 'image/png', name = 'report.png' },
            { type = 'text', text = 'done' },
          },
        },
      },
    },
  }
end

local function event(session_id, kind, data, created)
  data.sessionID = session_id
  return { id = 'evt-fixed', type = kind, created = created or 300, data = data }
end

describe('V2 protocol Observation interpretation', function()
  it('normalizes completed question text into the shared reply contract', function()
    local native = assistant('msg-question')
    native.content = {
      {
        type = 'tool',
        id = 'call-question',
        name = 'question',
        time = { created = 1 },
        state = {
          status = 'completed',
          input = {},
          content = {
            { type = 'text', text = 'First reply' },
            { type = 'file', uri = 'file:///tmp/reply.txt', mime = 'text/plain' },
            { type = 'text', text = 'Second reply\nMore detail' },
          },
        },
      },
    }
    local normalize = require('opencode.protocols.v2.normalize')
    local entry = normalize.mapped_message('ses-question', native)
    assert.equals('First reply\nSecond reply\nMore detail', entry.content[1].answer_text)

    native.content[1].state = { status = 'running', input = {} }
    entry = normalize.mapped_message('ses-question', native)
    assert.is_nil(entry.content[1].answer_text)
  end)

  it('preserves native skill attachments while preparing a message', function()
    local observed = observation('ses-skill')
    local skills = { { id = 'skill-id', mention = { start_byte = 0, end_byte = 7 } } }
    local params, update = observed:prepare_message({ skills = skills }, {})
    assert.same({ skills = skills }, params)
    assert.same({}, update)
  end)

  it('refreshes messages after successful native skill activation', function()
    local observed = observation('ses-skill')
    local operations = observed._connection.operations
    local original = operations.activate_skill
    local original_refresh = observed._start_resource
    local refreshed
    operations.activate_skill = function(_, session_id, skill_id)
      assert.equals('ses-skill', session_id)
      assert.equals('native-id', skill_id)
      return require('opencode.promise').new():resolve(true)
    end
    observed._start_resource = function(_, resource)
      refreshed = resource
    end
    assert.is_true(observed:activate_skill('native-id'):wait())
    assert.equals('messages', refreshed)
    operations.activate_skill = original
    observed._start_resource = original_refresh
  end)

  it('refreshes messages when a background completion notification arrives', function()
    local observed = observation('ses-bg')
    local original = observed._start_resource
    local refreshed
    observed._start_resource = function(_, resource)
      refreshed = resource
    end

    assert.is_true(observation_module.ingest_event(
      observed,
      event('ses-bg', 'session.synthetic', {
        text = '<shell id="sh_1" state="completed" command="make build">\nexit 0\n</shell>',
        metadata = { source = 'shell', shellID = 'sh_1', state = 'completed', exit = 0 },
      })
    ))
    assert.equals('messages', refreshed)
    assert.equals('stale', observed:read().sync.messages.state)

    observed._start_resource = original
  end)

  it('records background completions steered through the inbox of a busy session', function()
    local observed = observation('ses-bg')
    observation_module.ingest_snapshot(observed, {
      {
        id = 'msg-assistant',
        type = 'assistant',
        agent = 'build',
        model = { providerID = 'provider', id = 'model' },
        time = { created = 200 },
        content = {
          {
            type = 'tool',
            id = 'call-shell',
            name = 'shell',
            executed = true,
            time = { created = 201 },
            state = {
              status = 'completed',
              input = { command = 'make build', background = true },
              metadata = { status = 'running', truncated = false, shellID = 'sh_1' },
              content = {},
            },
          },
        },
      },
    })
    local background_tasks = require('opencode.services.background_tasks')
    assert.equals(1, background_tasks.count_observed(observed).shells)

    assert.is_true(observation_module.ingest_event(
      observed,
      event('ses-bg', 'session.inbox.enqueued', {
        inboxID = 'msg-completion',
        item = {
          type = 'synthetic',
          payload = {
            text = '<shell id="sh_1" state="completed" command="make build">\nbuilt\n</shell>',
            description = 'make build',
            metadata = { source = 'shell', shellID = 'sh_1', jobID = 'sh_1', state = 'completed', exit = 0 },
          },
          delivery = 'steer',
        },
      })
    ))

    local completion = observed:read().entries_by_id['msg-completion']
    assert.equals('sh_1', completion.background_result.id)
    assert.equals('built', completion.background_result.text)
    assert.equals(0, background_tasks.count_observed(observed).total)
  end)

  it('ignores inbox synthetic items that are not background completions', function()
    local observed = observation('ses-bg')

    assert.is_false(observation_module.ingest_event(
      observed,
      event('ses-bg', 'session.inbox.enqueued', {
        inboxID = 'msg-context',
        item = { type = 'synthetic', payload = { text = 'embedded context', metadata = { source = 'acp' } } },
      })
    ))
    assert.is_nil(observed:read().entries_by_id['msg-context'])
  end)

  it('ignores synthetic messages that are not background completions', function()
    local observed = observation('ses-bg')
    local original = observed._start_resource
    local refreshed
    observed._start_resource = function(_, resource)
      refreshed = resource
    end

    assert.is_false(observation_module.ingest_event(
      observed,
      event('ses-bg', 'session.synthetic', {
        text = 'embedded context',
        metadata = { source = 'acp' },
      })
    ))
    assert.is_nil(refreshed)

    observed._start_resource = original
  end)

  it('validates a complete snapshot before replacing existing entries', function()
    local observed = observation('ses-target')
    local message = assistant('msg-assistant')
    observation_module.ingest_snapshot(observed, { message })
    local state = observed:read()
    local entry = state.entries_by_id['msg-assistant']
    local previous = vim.deepcopy(entry)
    local replacement = vim.deepcopy(message)
    replacement.cost = 99

    assert.has_error(function()
      observation_module.ingest_snapshot(observed, { replacement, vim.deepcopy(replacement) })
    end)
    assert.equals(entry, state.entries_by_id['msg-assistant'])
    assert.same(previous, entry)
    assert.same({ 'msg-assistant' }, state.entry_order)
    assert.has_error(function()
      observation_module.ingest_snapshot(observed, { { id = 'msg-invalid', type = 'assistant' }, replacement })
    end)
    assert.same(previous, entry)
    assert.same({ 'msg-assistant' }, state.entry_order)
    observation_module.ingest_snapshot(observed, { replacement })
    assert.equals(entry, state.entries_by_id['msg-assistant'])
    assert.equals(99, entry.cost)
  end)

  it('rejects a message id with a colon, which would make synthesized part ids ambiguous', function()
    local observed = observation('ses-target')
    observation_module.ingest_snapshot(observed, { assistant('msg-assistant') })

    local ok, err = pcall(observation_module.ingest_snapshot, observed, { assistant('msg:collide') })

    assert.is_false(ok)
    assert.matches('message id must not contain', tostring(err))
    assert.same({ 'msg-assistant' }, observed:read().entry_order)
  end)

  it('projects newest-first native snapshots into chronological frozen facts', function()
    local observed = observation('ses-target')
    observation_module.ingest_snapshot(observed, {
      { id = 'msg-idle', type = 'idle', time = { created = 250 }, outcome = 'succeeded' },
      assistant('msg-assistant'),
      {
        id = 'msg-user',
        type = 'user',
        time = { created = 100 },
        text = '中😀@file @review',
        files = {
          {
            data = 'YQ==',
            mime = 'text/plain',
            source = { type = 'uri', uri = 'file:///server/file' },
            name = 'file',
            mention = { text = '@file', start = 3, ['end'] = 8 },
          },
        },
        agents = { { name = 'review', mention = { text = '@review', start = 9, ['end'] = 16 } } },
        skills = {},
      },
    })
    local state = observed:read()

    assert.same({ 'msg-user', 'msg-assistant' }, state.entry_order)
    assert.is_nil(state.entries_by_id['msg-idle'])
    local user = state.entries_by_id['msg-user']
    assert.equals('user', user.kind)
    assert.same({ text = '@file', start_byte = 7, end_byte = 12 }, user.content[2].mention)
    assert.same({ kind = 'resource', uri = 'file:///server/file' }, user.content[2].source)
    assert.same({ text = '@review', start_byte = 13, end_byte = 20 }, user.content[3].mention)

    local reply = state.entries_by_id['msg-assistant']
    assert.same({ providerID = 'provider', modelID = 'model', variant = 'high' }, reply.model)
    assert.same({ created = 200, streamed = 220, completed = 240 }, reply.time)
    assert.same({ start = 'snap-start', ['end'] = 'snap-end', files = { 'main.lua' } }, reply.snapshot)
    assert.same({ input = 10, output = 5, reasoning = 2, cache = { read = 3, write = 1 } }, reply.tokens)
    assert.equals('msg-assistant:reasoning:0', reply.content[1].id)
    assert.equals('msg-assistant:text:0', reply.content[2].id)
    local tool = reply.content[3]
    assert.equals('msg-assistant:tool:tool-1', tool.id)
    assert.equals('tool-1', tool.call_id)
    assert.equals('completed', tool.state)
    assert.is_nil(tool.metadata)
    assert.same({ { path = 'main.lua', diff = '@@ -9,1 +9,1 @@\n-old\n+new' } }, tool.changes)
    assert.is_nil(reply.content[1].provider_state)
    assert.same({ 'text', 'file', 'text' }, { tool.result[1].kind, tool.result[2].kind, tool.result[3].kind })
    assert.is_nil(tool.result[1].id)
    assert.equals('current', state.sync.messages.state)
  end)

  it('projects native file and skill tool inputs into formatter fields', function()
    local observed = observation('ses-target')
    local message = assistant('msg-tools')
    message.content = {
      {
        type = 'tool',
        id = 'tool-read',
        name = 'read',
        time = { created = 201, ran = 202, completed = 203 },
        state = {
          status = 'completed',
          input = { filePath = '/server/project/README.md' },
          content = { { type = 'text', text = '<path>/server/project/README.md</path>' } },
        },
      },
      {
        type = 'tool',
        id = 'tool-skill',
        name = 'skill',
        time = { created = 204, ran = 205, completed = 206 },
        state = {
          status = 'completed',
          input = {},
          metadata = { name = 'context7-cli' },
          content = { { type = 'text', text = 'loaded' } },
        },
      },
      {
        type = 'tool',
        id = 'tool-read-path',
        name = 'read',
        time = { created = 207, ran = 208, completed = 209 },
        state = {
          status = 'completed',
          input = { path = '/server/project/lua/init.lua' },
          content = { { type = 'text', text = '<path>/server/project/lua/init.lua</path>' } },
        },
      },
      {
        type = 'tool',
        id = 'tool-edit-path',
        name = 'edit',
        time = { created = 210, ran = 211, completed = 212 },
        state = {
          status = 'completed',
          input = {
            path = '/server/project/lua/init.lua',
            oldString = 'old',
            newString = 'new',
          },
          metadata = {
            files = {
              { file = 'init.lua', patch = '@@ -1,1 +1,1 @@\n-old\n+new' },
            },
          },
          content = { { type = 'text', text = 'edited' } },
        },
      },
    }
    observation_module.ingest_snapshot(observed, { message })

    local content = observed:read().entries_by_id['msg-tools'].content
    assert.same({ path = '/server/project/README.md' }, content[1].target)
    assert.equals('context7-cli', content[2].input.name)
    assert.same({ path = '/server/project/lua/init.lua' }, content[3].target)
    assert.same({
      { path = '/server/project/lua/init.lua', diff = '@@ -1,1 +1,1 @@\n-old\n+new' },
    }, content[4].changes)
  end)

  it('projects V2 subagent session metadata into a navigable child session', function()
    local observed = observation('ses-target')
    local message = assistant('msg-subagent')
    message.content = {
      {
        type = 'tool',
        id = 'tool-subagent',
        name = 'subagent',
        time = { created = 201, ran = 202, completed = 203 },
        state = {
          status = 'completed',
          input = { agent = 'explore', description = 'inspect repository' },
          metadata = { sessionID = 'ses-child' },
          content = { { type = 'text', text = 'Found two callers' } },
        },
      },
    }

    observation_module.ingest_snapshot(observed, { message })
    local part = observed:read().entries_by_id['msg-subagent'].content[1]
    assert.same({ id = 'ses-child' }, part.child_session)
    assert.equals('explore', part.input.agent)
    assert.equals('Found two callers', part.result[1].text)
  end)

  it('projects V2 grep match counts from metadata or result text', function()
    local observed = observation('ses-target')
    local message = assistant('msg-grep')
    message.content = {
      {
        type = 'tool',
        id = 'grep-metadata',
        name = 'grep',
        time = { created = 1 },
        state = {
          status = 'completed',
          input = { pattern = 'foo' },
          metadata = { matches = 3, truncated = true },
          content = { { type = 'text', text = 'Found 2 matches\nfile.lua: foo' } },
        },
      },
      {
        type = 'tool',
        id = 'grep-result',
        name = 'grep',
        time = { created = 2 },
        state = {
          status = 'completed',
          input = { pattern = 'bar' },
          content = { { type = 'text', text = 'Found 1 match\nfile.lua: bar' } },
        },
      },
      {
        type = 'tool',
        id = 'grep-empty',
        name = 'grep',
        time = { created = 3 },
        state = {
          status = 'completed',
          input = { pattern = 'missing' },
          metadata = { count = 0 },
          content = { { type = 'text', text = 'No matches found' } },
        },
      },
      {
        type = 'tool',
        id = 'grep-empty-result',
        name = 'grep',
        time = { created = 4 },
        state = {
          status = 'completed',
          input = { pattern = 'missing' },
          content = { { type = 'text', text = 'No matches found' } },
        },
      },
    }

    observation_module.ingest_snapshot(observed, { message })
    local content = observed:read().entries_by_id['msg-grep'].content
    assert.same({ count = 3, truncated = true }, content[1].search)
    assert.same({ count = 1 }, content[2].search)
    assert.same({ count = 0 }, content[3].search)
    assert.same({ count = 0 }, content[4].search)
    local formatted =
      require('opencode.ui.formatter').format_part(content[2], observed:read().entries_by_id['msg-grep'], true)
    assert.equals('Found `1` match', formatted.lines[2])
  end)

  it('projects V2 glob file counts and truncation into formatted output', function()
    local observed = observation('ses-target')
    local message = assistant('msg-glob')
    message.content = {
      {
        type = 'tool',
        id = 'glob-metadata',
        name = 'glob',
        time = { created = 1 },
        state = {
          status = 'completed',
          input = { pattern = '**/*.lua' },
          metadata = { count = 3, truncated = true },
          content = { { type = 'text', text = 'a.lua\nb.lua\nc.lua' } },
        },
      },
      {
        type = 'tool',
        id = 'glob-empty',
        name = 'glob',
        time = { created = 2 },
        state = {
          status = 'completed',
          input = { pattern = '**/*.missing' },
          metadata = { count = 0, truncated = false },
          content = { { type = 'text', text = 'No files found' } },
        },
      },
      {
        type = 'tool',
        id = 'glob-matches',
        name = 'glob',
        time = { created = 3 },
        state = {
          status = 'completed',
          input = { pattern = '**/*.txt' },
          metadata = { matches = 1 },
          content = { { type = 'text', text = 'a.txt' } },
        },
      },
    }

    observation_module.ingest_snapshot(observed, { message })
    local entry = observed:read().entries_by_id['msg-glob']
    assert.same({ count = 3, truncated = true }, entry.content[1].search)
    assert.same({ count = 0, truncated = false }, entry.content[2].search)
    assert.same({ count = 1 }, entry.content[3].search)
    local formatter = require('opencode.ui.formatter')
    assert.equals('Found more than `3` file(s):', formatter.format_part(entry.content[1], entry, true).lines[2])
    assert.equals('Found `0` file(s):', formatter.format_part(entry.content[2], entry, true).lines[2])
    assert.equals('Found `1` file(s):', formatter.format_part(entry.content[3], entry, true).lines[2])
  end)

  it('keeps each native kind as a distinct Entry shape', function()
    local observed = observation('ses-target')
    observation_module.ingest_snapshot(observed, {
      {
        id = 'loc',
        type = 'location-switched',
        time = { created = 8 },
        location = { directory = '/b' },
        projectID = 'p',
        subpath = 'b',
      },
      { id = 'model', type = 'model-switched', time = { created = 7 }, model = { providerID = 'p', id = 'm' } },
      { id = 'agent', type = 'agent-switched', time = { created = 6 }, agent = 'build', previous = 'plan' },
      {
        id = 'compact',
        type = 'compaction',
        time = { created = 5 },
        status = 'completed',
        reason = 'auto',
        summary = 's',
        recent = 'r',
      },
      {
        id = 'shell',
        type = 'shell',
        time = { created = 4, completed = 5 },
        shellID = 'sh',
        command = 'pwd',
        status = 'completed',
        exit = 0,
        output = '/tmp',
      },
      { id = 'skill', type = 'skill', time = { created = 3 }, skill = 'sk', name = 'review', text = 'rules' },
      { id = 'system', type = 'system', time = { created = 2 }, text = 'catalog', description = 'updated' },
      { id = 'synthetic', type = 'synthetic', time = { created = 1 }, text = 'context' },
    })
    local state = observed:read()
    assert.same({ 'synthetic', 'system', 'skill', 'shell', 'compact', 'agent', 'model', 'loc' }, state.entry_order)
    assert.equals('updated', state.entries_by_id.system.description)
    assert.equals('sk', state.entries_by_id.skill.skill_id)
    assert.equals('sh', state.entries_by_id.shell.shell_id)
    assert.equals('completed', state.entries_by_id.compact.state)
    assert.equals('plan', state.entries_by_id.agent.previous)
    assert.equals('m', state.entries_by_id.model.model.modelID)
    assert.equals('/b', state.entries_by_id.loc.location.directory)
  end)

  it('prepends an older native page once without reversing its chronological order', function()
    local observed = observation('ses-target')
    local function user(id, created)
      return { id = id, type = 'user', time = { created = created }, text = id, files = {}, agents = {}, skills = {} }
    end
    observation_module.ingest_snapshot(observed, { user('B', 4), user('A', 3) })
    observation_module.ingest_snapshot(observed, { user('Y', 2), user('Z', 1) }, true)
    assert.same({ 'Z', 'Y', 'A', 'B' }, observed:read().entry_order)

    observation_module.ingest_snapshot(observed, { user('Y', 2), user('Z', 1) }, true)
    assert.same({ 'Z', 'Y', 'A', 'B' }, observed:read().entry_order)
  end)

  it('projects an external user inbox event with its eventual snapshot identity', function()
    local observed = observation('ses-target')
    assert.is_true(observation_module.ingest_event(
      observed,
      event('ses-target', 'session.inbox.enqueued', {
        inboxID = 'msg-user',
        item = {
          type = 'user',
          delivery = 'steer',
          payload = { text = 'from another client', files = {}, agents = {} },
        },
      }, 100)
    ))

    assert.same({ 'msg-user' }, observed:read().entry_order)
    assert.equals('user', observed:read().entries_by_id['msg-user'].kind)
    assert.equals('from another client', observed:read().entries_by_id['msg-user'].content[1].text)
  end)

  it('projects restart and instruction notices into messages', function()
    local observed = observation('ses-notice')

    local restart = event('ses-notice', 'session.synthetic', {
      text = 'The server restarted while you were working.',
      description = 'Continuing after restart',
    }, 100)
    restart.id = 'evt_restart'
    assert.is_true(observation_module.ingest_event(observed, restart))

    local instructions = event('ses-notice', 'session.instructions.updated', {
      delta = { ['core/mcp-guidance'] = 'hash-b', ['core/codemode'] = 'hash-a' },
      text = 'The available MCP server instructions have changed.',
    }, 101)
    instructions.id = 'evt_instructions'
    assert.is_true(observation_module.ingest_event(observed, instructions))

    local state = observed:read()
    assert.same({ 'msg_restart', 'msg_instructions' }, state.entry_order)
    local synthetic = state.entries_by_id['msg_restart']
    assert.equals('synthetic', synthetic.kind)
    assert.equals('Continuing after restart', synthetic.description)
    assert.equals('The server restarted while you were working.', synthetic.content[1].text)
    local system = state.entries_by_id['msg_instructions']
    assert.equals('system', system.kind)
    assert.equals('Instructions updated: core/codemode, core/mcp-guidance', system.description)
  end)

  it('ignores instruction updates that carry no rendered text', function()
    local observed = observation('ses-notice')
    local baseline = event('ses-notice', 'session.instructions.updated', {
      delta = { ['core/codemode'] = 'hash-a' },
    }, 100)
    assert.is_false(observation_module.ingest_event(observed, baseline))
    assert.same({}, observed:read().entry_order)
  end)

  it('applies native text, reasoning, and tool lifecycles with synthesized identities', function()
    local observed = observation('ses-target')
    assert.is_true(observation_module.ingest_event(
      observed,
      event('ses-target', 'session.step.started', {
        assistantMessageID = 'msg-live',
        agent = 'build',
        model = { providerID = 'p', id = 'm' },
        snapshot = 'snap-start',
      }, 100)
    ))
    for _, value in ipairs({
      event('ses-target', 'session.reasoning.started', { assistantMessageID = 'msg-live', ordinal = 0 }, 101),
      event(
        'ses-target',
        'session.reasoning.delta',
        { assistantMessageID = 'msg-live', ordinal = 0, delta = 'A' },
        102
      ),
      event('ses-target', 'session.text.started', { assistantMessageID = 'msg-live', ordinal = 0 }, 103),
      event('ses-target', 'session.text.delta', { assistantMessageID = 'msg-live', ordinal = 0, delta = 'B' }, 104),
      event(
        'ses-target',
        'session.reasoning.ended',
        { assistantMessageID = 'msg-live', ordinal = 0, text = 'AR' },
        105
      ),
      event('ses-target', 'session.text.ended', { assistantMessageID = 'msg-live', ordinal = 0, text = 'BT' }, 106),
      event('ses-target', 'session.reasoning.started', { assistantMessageID = 'msg-live', ordinal = 1 }, 107),
      event('ses-target', 'session.reasoning.ended', { assistantMessageID = 'msg-live', ordinal = 1, text = 'C' }, 108),
      event(
        'ses-target',
        'session.tool.input.started',
        { assistantMessageID = 'msg-live', id = 'tool-live', name = 'patch' },
        109
      ),
      event(
        'ses-target',
        'session.tool.input.delta',
        { assistantMessageID = 'msg-live', id = 'tool-live', delta = '{"path":' },
        110
      ),
      event(
        'ses-target',
        'session.tool.input.ended',
        { assistantMessageID = 'msg-live', id = 'tool-live', text = '{"path":"a"}' },
        111
      ),
      event(
        'ses-target',
        'session.tool.called',
        { assistantMessageID = 'msg-live', id = 'tool-live', input = { path = 'a' }, executed = false },
        112
      ),
      event(
        'ses-target',
        'session.tool.progress',
        { assistantMessageID = 'msg-live', id = 'tool-live', metadata = { progress = 1, arbitrary = true } },
        113
      ),
      event('ses-target', 'session.tool.success', {
        assistantMessageID = 'msg-live',
        id = 'tool-live',
        executed = true,
        content = { { type = 'text', text = 'ok' }, { type = 'file', uri = 'file:///x', mime = 'text/plain' } },
        metadata = {
          arbitrary = 'must-not-leak',
          files = {
            { file = 'live.lua', patch = '@@ -3,1 +3,1 @@\n-old\n+new' },
          },
        },
        resultState = { opaque = true },
      }, 114),
    }) do
      assert.is_true(observation_module.ingest_event(observed, value))
    end
    local entry = observed:read().entries_by_id['msg-live']
    assert.same(
      { 'reasoning', 'text', 'reasoning', 'tool' },
      vim.tbl_map(function(content)
        return content.kind
      end, entry.content)
    )
    assert.equals('AR', entry.content[1].text)
    assert.equals('BT', entry.content[2].text)
    assert.equals('C', entry.content[3].text)
    assert.equals('msg-live:reasoning:0', entry.content[1].id)
    assert.equals('msg-live:text:0', entry.content[2].id)
    assert.equals('msg-live:reasoning:1', entry.content[3].id)
    assert.equals('msg-live:tool:tool-live', entry.content[4].id)
    assert.equals('tool-live', entry.content[4].call_id)
    assert.equals('completed', entry.content[4].state)
    assert.is_nil(entry.content[4].metadata)
    assert.same({ { path = 'live.lua', diff = '@@ -3,1 +3,1 @@\n-old\n+new' } }, entry.content[4].changes)
    assert.is_nil(entry.content[4].provider_state)
    assert.is_nil(entry.content[4].provider_result_state)
    assert.same({ 'text', 'file' }, { entry.content[4].result[1].kind, entry.content[4].result[2].kind })

    local duplicate = event('ses-target', 'session.tool.failed', {
      assistantMessageID = 'msg-live',
      id = 'tool-live',
      executed = true,
      error = { name = 'Tool.Error', message = 'late' },
    }, 115)
    assert.is_false(observation_module.ingest_event(observed, duplicate))
    assert.equals('completed', entry.content[4].state)
    assert.is_nil(entry.content[4].error)
  end)

  it('maps the proven tool error names and preserves explicit false error fields', function()
    local observed = observation('ses-target')
    observation_module.ingest_event(
      observed,
      event('ses-target', 'session.step.started', {
        assistantMessageID = 'msg-error',
        agent = 'build',
        model = { providerID = 'p', id = 'm' },
      })
    )
    observation_module.ingest_event(
      observed,
      event('ses-target', 'session.tool.input.started', {
        assistantMessageID = 'msg-error',
        id = 'tool-error',
        name = 'bash',
      })
    )
    observation_module.ingest_event(
      observed,
      event('ses-target', 'session.tool.called', {
        assistantMessageID = 'msg-error',
        id = 'tool-error',
        input = { command = 'false' },
        executed = false,
      })
    )
    assert.is_true(observation_module.ingest_event(
      observed,
      event('ses-target', 'session.tool.failed', {
        assistantMessageID = 'msg-error',
        id = 'tool-error',
        executed = false,
        error = { name = 'Tool.Error', message = 'exit 1', retryable = false },
      })
    ))
    local tool = observed:read().entries_by_id['msg-error'].content[1]
    assert.equals('error', tool.state)
    assert.is_false(tool.executed)
    assert.is_false(tool.error.retryable)
  end)

  it('skips foreign or unidentified events and exposes the first protocol boundary failure', function()
    local observed = observation('ses-target')
    assert.is_false(observation_module.ingest_event(
      observed,
      event('ses-other', 'session.step.started', {
        assistantMessageID = 'msg-foreign',
        agent = 'build',
        model = { providerID = 'p', id = 'm' },
      })
    ))
    assert.is_nil(observed:read().entries_by_id['msg-foreign'])

    assert.is_false(observation_module.ingest_event(
      observed,
      event('ses-target', 'session.step.started', {
        agent = 'build',
        model = { providerID = 'p', id = 'm' },
      })
    ))
    assert.equals('error', observed:read().sync.messages.state)
    assert.matches('missing assistant identity', observed:read().sync.messages.error.message)

    assert.is_false(observation_module.ingest_event(
      observed,
      event('ses-target', 'session.tool.success', {
        assistantMessageID = 'msg-missing',
        content = { { type = 'text', text = 'x' } },
        executed = true,
      })
    ))
    assert.is_nil(observed:read().entries_by_id['msg-missing'])
    assert.matches('no assistant message', observed:read().sync.messages.error.message)
  end)
  it('keeps synthesized part identity stable across the event-to-snapshot handoff', function()
    local observed = observation('ses-target')
    observation_module.ingest_event(
      observed,
      event('ses-target', 'session.step.started', {
        assistantMessageID = 'msg-mix',
        agent = 'build',
        model = { providerID = 'p', id = 'm' },
      })
    )
    observation_module.ingest_event(
      observed,
      event('ses-target', 'session.text.started', { assistantMessageID = 'msg-mix', ordinal = 0 })
    )
    observation_module.ingest_event(
      observed,
      event('ses-target', 'session.text.delta', { assistantMessageID = 'msg-mix', ordinal = 0, delta = 'T0' })
    )
    observation_module.ingest_event(
      observed,
      event(
        'ses-target',
        'session.tool.input.started',
        { assistantMessageID = 'msg-mix', id = 'tool-mix', name = 'bash' }
      )
    )
    observation_module.ingest_event(
      observed,
      event('ses-target', 'session.reasoning.started', { assistantMessageID = 'msg-mix', ordinal = 0 })
    )
    observation_module.ingest_event(
      observed,
      event('ses-target', 'session.text.started', { assistantMessageID = 'msg-mix', ordinal = 1 })
    )

    local entry = observed:read().entries_by_id['msg-mix']
    assert.same(
      { 'text', 'tool', 'reasoning', 'text' },
      vim.tbl_map(function(content)
        return content.kind
      end, entry.content)
    )
    assert.same(
      {
        'msg-mix:text:0',
        'msg-mix:tool:tool-mix',
        'msg-mix:reasoning:0',
        'msg-mix:text:1',
      },
      vim.tbl_map(function(content)
        return content.id
      end, entry.content)
    )

    observation_module.ingest_snapshot(observed, {
      {
        id = 'msg-mix',
        type = 'assistant',
        agent = 'build',
        model = { providerID = 'p', id = 'm' },
        time = { created = 300, completed = 400 },
        snapshot = {},
        content = {
          { type = 'text', text = 'snap-t0' },
          {
            type = 'tool',
            id = 'tool-mix',
            name = 'bash',
            time = { created = 310 },
            state = { status = 'running', input = { command = 'ls' } },
          },
          { type = 'reasoning', text = 'snap-r0' },
          { type = 'text', text = 'snap-t1' },
        },
      },
    })
    local replaced = observed:read().entries_by_id['msg-mix']
    assert.same(
      {
        'msg-mix:text:0',
        'msg-mix:tool:tool-mix',
        'msg-mix:reasoning:0',
        'msg-mix:text:1',
      },
      vim.tbl_map(function(content)
        return content.id
      end, replaced.content)
    )

    assert.is_true(
      observation_module.ingest_event(
        observed,
        event('ses-target', 'session.text.delta', { assistantMessageID = 'msg-mix', ordinal = 0, delta = '!' })
      )
    )
    assert.is_true(
      observation_module.ingest_event(
        observed,
        event('ses-target', 'session.text.ended', { assistantMessageID = 'msg-mix', ordinal = 0, text = 'T0-final' })
      )
    )
    assert.equals('T0-final', replaced.content[1].text)
    assert.equals('msg-mix:text:0', replaced.content[1].id)
    assert.equals('snap-t1', replaced.content[4].text)

    assert.is_true(observation_module.ingest_event(
      observed,
      event('ses-target', 'session.tool.called', {
        assistantMessageID = 'msg-mix',
        id = 'tool-mix',
        input = { command = 'ls -a' },
        executed = false,
      })
    ))
    assert.is_true(observation_module.ingest_event(
      observed,
      event('ses-target', 'session.tool.success', {
        assistantMessageID = 'msg-mix',
        id = 'tool-mix',
        executed = true,
        content = { { type = 'text', text = 'done' } },
      })
    ))
    assert.equals('msg-mix:tool:tool-mix', replaced.content[2].id)
    assert.equals('tool-mix', replaced.content[2].call_id)
    assert.equals('completed', replaced.content[2].state)
  end)
end)

describe('V2 protocol editor-context attachments', function()
  it('maps editor-context file attachments onto the shared contract entry instead of plain files', function()
    local observed = observation('ses-target')
    local payload = vim.base64.encode(vim.json.encode({
      context_type = 'selection',
      file = { name = 'test.py' },
      content = 'selected code',
      lines = '1-2',
    }))
    observation_module.ingest_snapshot(observed, {
      {
        id = 'msg-user',
        type = 'user',
        time = { created = 100 },
        text = 'review this',
        files = {
          {
            data = payload,
            mime = 'text/plain',
            source = { type = 'inline' },
            name = 'editor-context:selection:test.py:1-2',
          },
          { data = 'YQ==', mime = 'text/plain', source = { type = 'inline' }, name = 'plain-note.txt' },
        },
        agents = {},
        skills = {},
      },
    })
    local state = observed:read()
    local entry = state.entries_by_id['msg-user']
    local kinds = {}
    for _, content in ipairs(entry.content) do
      kinds[#kinds + 1] = content.kind
    end
    assert.same({ 'text', 'editor_context', 'file' }, kinds)

    local context_entry = entry.content[2]
    assert.same('editor_context', context_entry.kind)
    assert.is_true(context_entry.synthetic)
    assert.equals('msg-user:file:1', context_entry.id)
    assert.same('selection', context_entry.source.kind)
    assert.same('test.py', context_entry.source.file_name)
    assert.same('1-2', context_entry.source.range)
    assert.same('selected code', context_entry.text)
    assert.equals('msg-user:file:2', entry.content[3].id)
  end)
end)
