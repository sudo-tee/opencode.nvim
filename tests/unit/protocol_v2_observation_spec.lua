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
        name = 'render',
        executed = true,
        time = { created = 206, ran = 207, completed = 210 },
        state = {
          status = 'completed',
          input = { path = 'main.lua' },
          metadata = { arbitrary = 'must-not-leak' },
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
    local tool = reply.content[3]
    assert.equals('tool-1', tool.id)
    assert.equals('completed', tool.state)
    assert.is_nil(tool.metadata)
    assert.is_nil(reply.content[1].provider_state)
    assert.same({ 'text', 'file', 'text' }, { tool.result[1].kind, tool.result[2].kind, tool.result[3].kind })
    assert.is_nil(tool.result[1].id)
    assert.equals('current', state.sync.messages.state)
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

  it('applies native text, reasoning, and tool lifecycles without synthetic identities', function()
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
        { assistantMessageID = 'msg-live', id = 'tool-live', name = 'render' },
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
        metadata = { arbitrary = 'must-not-leak' },
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
    assert.is_nil(entry.content[1].id)
    assert.is_nil(entry.content[2].id)
    assert.equals('completed', entry.content[4].state)
    assert.is_nil(entry.content[4].metadata)
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
end)

describe('V2 protocol editor-context attachments', function()
  it('maps editor-context file attachments onto the shared contract entry instead of plain files', function()
    local observed = observation('ses-target')
    local payload =
      vim.base64.encode(vim.json.encode({ context_type = 'selection', file = { name = 'test.py' }, content = 'selected code', lines = '1-2' }))
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
    assert.same('selection', context_entry.source.kind)
    assert.same('test.py', context_entry.source.file_name)
    assert.same('1-2', context_entry.source.range)
    assert.same('selected code', context_entry.text)
  end)
end)
