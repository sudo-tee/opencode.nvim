local assert = require('luassert')
local Promise = require('opencode.promise')

local function resolved(value)
  return Promise.new():resolve(value)
end

local function session(id, parent_id)
  return {
    id = id,
    parentID = parent_id,
    projectID = 'project',
    location = { directory = '/server/project' },
    title = id,
    cost = 0,
    tokens = {},
    time = { created = 1, updated = 2 },
  }
end

local function user(id, text, created)
  return {
    id = id,
    type = 'user',
    time = { created = created or 1 },
    text = text or id,
    files = {},
    agents = {},
    skills = {},
  }
end

local function connection()
  local value = require('opencode.opencode_server').from_custom('http://v2.test')
  value.protocol = 'v2'
  value.server_identity = { version = '2.0.1' }
  value.credential = { username = 'opencode' }
  value:mark_ready()
  return value
end

local function install_operations(value, overrides)
  local streams = {}
  local operations = {
    subscribe_events = function(owner, on_chunk, on_disconnect)
      local handle = { stopped = false }
      function handle:shutdown()
        self.stopped = true
      end
      owner:set_stream(handle)
      streams[#streams + 1] = { handle = handle, chunk = on_chunk, disconnect = on_disconnect }
      return handle
    end,
    get_session = function(_, id)
      return resolved(session(id))
    end,
    list_messages = function()
      return resolved({ data = {}, cursor = {} })
    end,
    list_sessions = function()
      return resolved({ data = {}, cursor = {} })
    end,
    list_active_sessions = function()
      return resolved({})
    end,
    list_inbox = function()
      return resolved({})
    end,
    list_permissions = function()
      return resolved({})
    end,
    list_questions = function()
      return resolved({})
    end,
  }
  for name, operation in pairs(overrides or {}) do
    operations[name] = operation
  end
  value.operations = operations
  return streams, operations
end

local function emit(stream, event)
  stream.chunk('data: ' .. vim.json.encode(event) .. '\n\n')
end

local function event(session_id, kind, data, created)
  data.sessionID = session_id
  return { id = 'evt-' .. kind, type = kind, created = created or 10, data = data }
end

local function flush(predicate)
  assert.is_true(vim.wait(500, predicate or function()
    return true
  end, 5))
end

describe('V2 protocol Observation runtime', function()
  it('forwards each valid SSE event to User autocmds once with documented payload', function()
    local value = connection()
    local streams = install_operations(value)
    local first = value:observe({ id = 'ses-a' })
    local second = value:observe({ id = 'ses-b' })
    local stop_first = first:watch({ 'messages' }, function() end)
    local stop_second = second:watch({ 'messages' }, function() end)
    local received = {}
    local group = vim.api.nvim_create_augroup('OpencodeV2SseAutocmdTest', { clear = true })
    vim.api.nvim_create_autocmd('User', {
      group = group,
      pattern = 'OpencodeEvent:*',
      callback = function(args)
        received[#received + 1] = { pattern = args.match, event = args.data.event }
      end,
    })

    local data = { sessionID = 'ses-a', detail = 'hello' }
    emit(streams[1], event('ses-a', 'custom.unknown', data))
    emit(streams[1], { type = 'custom.invalid', data = {} })

    assert.same(
      { { pattern = 'OpencodeEvent:custom.unknown', event = { type = 'custom.unknown', properties = data } } },
      received
    )
    vim.api.nvim_del_augroup_by_id(group)
    stop_first()
    stop_second()
  end)

  it('shares one event stream across Observations and stops it after the last watcher', function()
    local value = connection()
    local streams = install_operations(value)
    local first = value:observe({ id = 'ses-a' })
    local second = value:observe({ id = 'ses-b' })
    local stop_first = first:watch({ 'messages' }, function() end)
    local stop_second = second:watch({ 'inbox' }, function() end)
    flush(function()
      return first:read().sync.messages.state == 'current' and second:read().sync.inbox.state == 'current'
    end)

    assert.equals(1, #streams)
    assert.is_false(streams[1].handle.stopped)
    stop_first()
    assert.is_false(streams[1].handle.stopped)
    stop_second()
    assert.is_true(streams[1].handle.stopped)
    assert.is_nil(value._stream)
  end)

  it('commits inbox and message facts before notifying either watcher', function()
    local value = connection()
    local streams = install_operations(value)
    local observed = value:observe({ id = 'ses-main' })
    local foreign = value:observe({ id = 'ses-other' })
    local notifications = {}
    local stop = observed:watch({ 'messages', 'inbox' }, function(current, resource)
      if current:read().inbox.items_by_id['input-1'] then
        assert.equals('hello', current:read().entries_by_id['input-1'].content[1].text)
        notifications[resource] = (notifications[resource] or 0) + 1
      end
    end)
    local stop_foreign = foreign:watch({ 'messages', 'inbox' }, function() end)

    emit(
      streams[1],
      event('ses-main', 'session.inbox.enqueued', {
        inboxID = 'input-1',
        item = { type = 'user', delivery = 'queue', payload = { text = 'hello', files = {}, agents = {}, skills = {} } },
      })
    )

    assert.same({ messages = 1, inbox = 1 }, notifications)
    assert.is_nil(foreign:read().inbox.items_by_id['input-1'])
    assert.is_nil(foreign:read().entries_by_id['input-1'])
    stop()
    stop_foreign()
  end)

  it('routes nested form identities only to their owning session', function()
    local value = connection()
    local streams = install_operations(value)
    local observed = value:observe({ id = 'ses-main' })
    local foreign = value:observe({ id = 'ses-other' })
    local stop = observed:watch({ 'questions' }, function() end)
    local stop_foreign = foreign:watch({ 'questions' }, function() end)

    emit(streams[1], {
      type = 'form.created',
      created = 10,
      data = {
        form = {
          id = 'form-1',
          sessionID = 'ses-main',
          title = 'Continue?',
          fields = { { key = 'ok', type = 'boolean', required = true } },
        },
      },
    })
    emit(streams[1], event('ses-main', 'form.replied', { id = 'form-1', answer = { ok = true } }))

    assert.equals('answered', observed:read().question_requests_by_id['form-1'].status)
    assert.same({ ok = true }, observed:read().question_requests_by_id['form-1'].answers)
    assert.is_nil(foreign:read().question_requests_by_id['form-1'])
    stop()
    stop_foreign()
  end)

  it('projects 2.0.1 and later V2 file event names into the same fact', function()
    local value = connection()
    local streams = install_operations(value)
    local observed = value:observe({ id = 'ses-main' })
    local stop = observed:watch({ 'files' }, function() end)
    assert.equals('current', observed:read().sync.files.state)

    emit(streams[1], {
      id = 'evt-file-1',
      type = 'filesystem.changed',
      created = 10,
      data = { file = '/server/project/a.lua', event = 'change' },
    })
    emit(streams[1], {
      id = 'evt-file-2',
      type = 'file.edited',
      created = 11,
      data = { file = '/server/project/b.lua' },
    })
    assert.equals(2, observed:read().files.revision)
    assert.same({ path = '/server/project/b.lua', event = 'change' }, observed:read().files.last)

    emit(streams[1], { id = 'evt-file-bad', type = 'filesystem.changed', created = 13, data = {} })
    assert.equals('error', observed:read().sync.files.state)
    assert.equals(2, observed:read().files.revision)
    stop()
  end)

  it('updates session usage and notifies session watchers', function()
    local value = connection()
    local streams = install_operations(value)
    local observed = value:observe({ id = 'ses-main' })
    local notifications = 0
    local stop = observed:watch({ 'session' }, function()
      notifications = notifications + 1
    end)
    local before = notifications

    emit(
      streams[1],
      event('ses-main', 'session.usage.updated', {
        cost = 1.25,
        tokens = {
          input = 10,
          output = 20,
          reasoning = 30,
          cache = { read = 40, write = 50 },
        },
      }, 20)
    )

    assert.equals(1.25, observed:read().session.cost)
    assert.same({
      input = 10,
      output = 20,
      reasoning = 30,
      cache = { read = 40, write = 50 },
    }, observed:read().session.tokens)
    assert.is_true(notifications > before)
    stop()
  end)

  it('records a diagnostic for invalid session usage without raising', function()
    local value = connection()
    local streams = install_operations(value)
    local observed = value:observe({ id = 'ses-main' })
    local stop = observed:watch({ 'session' }, function() end)

    local ok, err = pcall(function()
      emit(streams[1], event('ses-main', 'session.usage.updated', { cost = 'invalid', tokens = {} }, 20))
    end)

    assert.is_true(ok, tostring(err))
    assert.equals('error', observed:read().sync.session.state)
    assert.equals('protocol_contract', observed:read().sync.session.error.kind)
    stop()
  end)

  it('reads each resource independently and keeps one failure scoped to that resource', function()
    local value = connection()
    local permission_failure = Promise.new():reject('permission unavailable')
    install_operations(value, {
      get_session = function(_, id)
        return resolved(session(id))
      end,
      list_sessions = function(_, _, cursor)
        if cursor == nil then
          return resolved({
            data = { session('ses-child', 'ses-main'), session('ses-foreign', 'other') },
            cursor = { next = 'next' },
          })
        end
        return resolved({ data = { session('ses-child-2', 'ses-main') }, cursor = {} })
      end,
      list_active_sessions = function()
        return resolved({ ['ses-main'] = { type = 'running' } })
      end,
      list_inbox = function()
        return resolved({
          {
            id = 'msg-inbox',
            sessionID = 'ses-main',
            type = 'user',
            timeCreated = 4,
            delivery = 'queue',
            payload = { text = 'queued' },
          },
        })
      end,
      list_permissions = function()
        return permission_failure
      end,
      list_questions = function()
        return resolved({
          {
            id = 'frm-1',
            sessionID = 'ses-main',
            title = 'Choose',
            fields = { { key = 'ok', type = 'boolean', required = true } },
          },
        })
      end,
    })
    local observed = value:observe({ id = 'ses-main' })
    local stop = observed:watch(
      { 'session', 'children', 'inbox', 'execution', 'permissions', 'questions' },
      function() end
    )
    flush(function()
      return observed:read().sync.questions.state == 'current'
        and observed:read().sync.permissions.state == 'error'
        and observed:read().sync.children.state == 'current'
    end)
    local state = observed:read()
    assert.equals('/server/project', state.session.location.directory)
    assert.same({ 'ses-child', 'ses-child-2' }, state.children.order)
    assert.equals('pending', state.inbox.items_by_id['msg-inbox'].status)
    assert.equals('running', state.execution.activity)
    assert.equals('operation', state.sync.permissions.error.kind)
    assert.equals('pending', state.question_requests_by_id['frm-1'].status)
    assert.equals('current', state.sync.session.state)
    stop()
  end)

  it('discards a snapshot crossed by an online change and ignores a late GET after release', function()
    local value = connection()
    local requests = { Promise.new(), Promise.new(), Promise.new() }
    local count = 0
    local streams = install_operations(value, {
      list_messages = function()
        count = count + 1
        return requests[count]
      end,
    })
    local observed = value:observe({ id = 'ses-main' })
    local notifications = 0
    local stop = observed:watch({ 'messages' }, function()
      notifications = notifications + 1
    end)
    assert.equals('loading', observed:read().sync.messages.state)

    for _ = 1, 100 do
      emit(
        streams[1],
        event('ses-main', 'session.step.started', {
          assistantMessageID = 'msg-live',
          agent = 'build',
          model = { providerID = 'p', id = 'm' },
        }, 20)
      )
    end
    flush(function()
      return notifications == 101
    end)
    assert.equals(1, count)
    requests[1]:resolve({ data = { user('msg-old', 'old') }, cursor = {} })
    flush(function()
      return count == 2
    end)
    assert.is_nil(observed:read().entries_by_id['msg-old'])
    requests[2]:resolve({ data = { user('msg-authority', 'authority') }, cursor = {} })
    flush(function()
      return observed:read().sync.messages.state == 'current'
    end)
    assert.same({ 'msg-authority' }, observed:read().entry_order)
    assert.equals(104, notifications)
    assert.equals(2, count)

    stop()
    assert.same({}, observed:read().entry_order)
    local replacement = value:observe({ id = 'ses-main' })
    local replacement_stop = replacement:watch({ 'messages' }, function() end)
    replacement_stop()
    requests[3]:resolve({ data = { user('msg-late', 'late') }, cursor = {} })
    vim.wait(20)
    assert.is_nil(replacement:read().entries_by_id['msg-late'])
  end)

  it('uses the native cursor and prepends older messages without overwriting online facts', function()
    local value = connection()
    local calls = {}
    install_operations(value, {
      list_messages = function(_, _, cursor, limit)
        calls[#calls + 1] = { cursor = cursor, limit = limit }
        if cursor == nil then
          return resolved({ data = { user('B', 'B', 4), user('A', 'A', 3) }, cursor = { next = 'older-cursor' } })
        end
        return resolved({ data = { user('Y', 'Y', 2), user('Z', 'Z', 1) }, cursor = {} })
      end,
    })
    local observed = value:observe({ id = 'ses-main' })
    local stop = observed:watch({ 'messages' }, function() end)
    flush(function()
      return observed:read().sync.messages.state == 'current'
    end)
    observed:load_older():wait()
    assert.same({ { cursor = nil, limit = 50 }, { cursor = 'older-cursor', limit = 50 } }, calls)
    assert.same({ 'Z', 'Y', 'A', 'B' }, observed:read().entry_order)
    stop()
  end)

  it('keeps terminal inbox and form facts when a stale pending snapshot arrives', function()
    local value = connection()
    local inbox_page, form_page, permission_page = Promise.new(), Promise.new(), Promise.new()
    local streams = install_operations(value, {
      list_inbox = function()
        return inbox_page
      end,
      list_questions = function()
        return form_page
      end,
      list_permissions = function()
        return permission_page
      end,
    })
    local observed = value:observe({ id = 'ses-main', location = { directory = '/wrong-hint' } })
    local stop = observed:watch({ 'inbox', 'permissions', 'questions' }, function() end)
    emit(streams[1], event('ses-main', 'session.inbox.cancelled', { inboxID = 'msg-input' }, 20))
    emit(
      streams[1],
      event('ses-main', 'permission.asked', {
        id = 'per-1',
        action = 'read',
        resources = { '/tmp' },
      }, 20)
    )
    emit(streams[1], event('ses-main', 'permission.replied', { requestID = 'per-1', reply = 'reject' }, 21))
    emit(streams[1], event('ses-main', 'form.replied', { id = 'frm-1', answer = { ok = true } }, 21))
    inbox_page:resolve({
      {
        id = 'msg-input',
        sessionID = 'ses-main',
        type = 'user',
        timeCreated = 10,
        delivery = 'queue',
        payload = { text = 'x' },
      },
    })
    form_page:resolve({
      { id = 'frm-1', sessionID = 'ses-main', title = 'Choose', fields = { { key = 'ok', type = 'boolean' } } },
    })
    permission_page:resolve({
      { id = 'per-1', sessionID = 'ses-main', action = 'read', resources = { '/tmp' } },
    })
    flush(function()
      return observed:read().inbox.items_by_id['msg-input'] ~= nil
        and observed:read().question_requests_by_id['frm-1'] ~= nil
        and observed:read().permission_requests_by_id['per-1'] ~= nil
    end)
    assert.equals('cancelled', observed:read().inbox.items_by_id['msg-input'].status)
    assert.equals('answered', observed:read().permission_requests_by_id['per-1'].status)
    assert.equals('reject', observed:read().permission_requests_by_id['per-1'].answer)
    assert.equals('answered', observed:read().question_requests_by_id['frm-1'].status)
    assert.is_true(observed:read().question_requests_by_id['frm-1'].answers.ok)
    assert.equals('/server/project', observed:read().session.location.directory)
    stop()
  end)

  it('maps optional permission metadata from snapshots and events without inventing missing previews', function()
    local value = connection()
    local native = {
      id = 'per-preview',
      sessionID = 'ses-main',
      action = 'bash',
      resources = { 'git *' },
      message = 'Inspect changes',
      metadata = { command = 'git status --short' },
    }
    local streams = install_operations(value, {
      list_permissions = function()
        return resolved({ native })
      end,
    })
    local observed = value:observe({ id = 'ses-main' })
    local stop = observed:watch({ 'permissions' }, function() end)
    flush(function()
      return observed:read().sync.permissions.state == 'current'
    end)
    local request = observed:read().permission_requests_by_id['per-preview']
    assert.same({ command = 'git status --short' }, request.preview)
    assert.equals('Inspect changes', request.message)
    assert.same({ 'git *' }, request.resources)
    assert.equals('git status --short', native.metadata.command)

    emit(
      streams[1],
      event('ses-main', 'permission.asked', {
        id = 'per-edit',
        action = 'edit',
        resources = { 'file.lua' },
        metadata = { diff = '@@ -1 +1 @@\n-old\n+new', filePath = 'file.lua' },
      })
    )
    assert.same(
      { diff = '@@ -1 +1 @@\n-old\n+new', path = 'file.lua' },
      observed:read().permission_requests_by_id['per-edit'].preview
    )
    emit(
      streams[1],
      event('ses-main', 'permission.asked', {
        id = 'per-plain',
        action = 'read',
        resources = { 'file.lua' },
      })
    )
    assert.is_nil(observed:read().permission_requests_by_id['per-plain'].preview)
    local normalize = require('opencode.protocols.v2.normalize')
    assert.has_error(function()
      normalize.mapped_permission({
        id = 'per-invalid',
        sessionID = 'ses-main',
        action = 'bash',
        resources = {},
        metadata = { command = 42 },
      })
    end)
    assert.is_nil(observed:read().permission_requests_by_id['per-invalid'])
    assert.has_error(function()
      normalize.mapped_permission({
        id = 'per-invalid-source',
        sessionID = 'ses-main',
        action = 'bash',
        resources = {},
        source = { type = 'tool', messageID = 'msg-tool' },
      })
    end)
    assert.is_nil(observed:read().permission_requests_by_id['per-invalid-source'])
    stop()
  end)

  it('fills previews from the exact linked tool and publishes them after online tool input arrives', function()
    local value = connection()
    local streams = install_operations(value)
    local observed = value:observe({ id = 'ses-main' })
    local permission_changes = 0
    local stop = observed:watch({ 'messages', 'permissions' }, function(_, resource)
      if resource == 'permissions' then
        permission_changes = permission_changes + 1
      end
    end)
    flush(function()
      return observed:read().sync.messages.state == 'current' and observed:read().sync.permissions.state == 'current'
    end)
    emit(
      streams[1],
      event('ses-main', 'permission.asked', {
        id = 'per-linked',
        action = 'bash',
        resources = { 'git *' },
        source = { type = 'tool', messageID = 'msg-tool', id = 'tool-right' },
      })
    )
    emit(
      streams[1],
      event('ses-main', 'permission.asked', {
        id = 'per-authoritative',
        action = 'bash',
        resources = { 'git *' },
        message = 'Server description',
        metadata = { command = 'server command' },
        source = { type = 'tool', messageID = 'msg-tool', id = 'tool-right' },
      })
    )
    emit(
      streams[1],
      event('ses-main', 'session.step.started', {
        assistantMessageID = 'msg-tool',
        agent = 'build',
        model = { providerID = 'p', id = 'm' },
      })
    )
    local function called(id, command)
      emit(
        streams[1],
        event('ses-main', 'session.tool.input.started', {
          assistantMessageID = 'msg-tool',
          id = id,
          name = 'bash',
        })
      )
      emit(
        streams[1],
        event('ses-main', 'session.tool.called', {
          assistantMessageID = 'msg-tool',
          id = id,
          name = 'bash',
          input = { command = command, description = 'Inspect changes' },
        })
      )
    end
    called('tool-wrong', 'wrong command')
    assert.is_nil(observed:read().permission_requests_by_id['per-linked'].preview.command)
    local before = permission_changes
    called('tool-right', 'git status --short')
    local request = observed:read().permission_requests_by_id['per-linked']
    assert.equals('git status --short', request.preview.command)
    assert.equals('Inspect changes', request.message)
    assert.equals(before + 1, permission_changes)
    local authoritative = observed:read().permission_requests_by_id['per-authoritative']
    assert.equals('server command', authoritative.preview.command)
    assert.equals('Server description', authoritative.message)
    emit(streams[1], event('ses-main', 'permission.replied', { requestID = 'per-linked', reply = 'once' }))
    assert.equals('answered', request.status)
    stop()
  end)

  for _, permissions_first in ipairs({ true, false }) do
    it(
      'restores linked edit previews regardless of snapshot arrival order: permissions first '
        .. tostring(permissions_first),
      function()
        local value = connection()
        local permission_page, message_page = Promise.new(), Promise.new()
        install_operations(value, {
          list_messages = function()
            return message_page
          end,
          list_permissions = function()
            return permission_page
          end,
        })
        local observed = value:observe({ id = 'ses-main' })
        local stop = observed:watch({ 'messages', 'permissions' }, function() end)
        local permissions = {
          {
            id = 'per-edit',
            sessionID = 'ses-main',
            action = 'edit',
            resources = { 'file.lua' },
            message = 'Edit file',
            source = { type = 'tool', messageID = 'msg-edit', id = 'tool-edit' },
          },
          {
            id = 'per-diff-only',
            sessionID = 'ses-main',
            action = 'edit',
            resources = { 'file.lua' },
            metadata = { diff = 'server diff' },
            source = { type = 'tool', messageID = 'msg-edit', id = 'tool-edit' },
          },
          {
            id = 'per-conflict',
            sessionID = 'ses-main',
            action = 'edit',
            resources = { 'other.lua' },
            metadata = { filePath = 'other.lua' },
            source = { type = 'tool', messageID = 'msg-edit', id = 'tool-edit' },
          },
        }
        local page = {
          data = {
            {
              id = 'msg-edit',
              type = 'assistant',
              agent = 'build',
              time = { created = 1 },
              content = {
                {
                  type = 'tool',
                  id = 'tool-edit',
                  name = 'edit',
                  time = { created = 1 },
                  state = {
                    status = 'running',
                    input = { filePath = 'file.lua' },
                    metadata = { diff = '@@ -1 +1 @@\n-old\n+new' },
                  },
                },
              },
            },
          },
          cursor = {},
        }
        if permissions_first then
          permission_page:resolve(permissions)
          flush(function()
            return observed:read().sync.permissions.state == 'current'
          end)
          message_page:resolve(page)
        else
          message_page:resolve(page)
          flush(function()
            return observed:read().sync.messages.state == 'current'
          end)
          permission_page:resolve(permissions)
        end
        flush(function()
          return observed:read().sync.messages.state == 'current'
            and observed:read().sync.permissions.state == 'current'
        end)
        local preview = observed:read().permission_requests_by_id['per-edit'].preview
        assert.equals('@@ -1 +1 @@\n-old\n+new', preview.diff)
        assert.equals('file.lua', preview.path)
        local diff_only = observed:read().permission_requests_by_id['per-diff-only'].preview
        assert.equals('server diff', diff_only.diff)
        assert.equals('file.lua', diff_only.path)
        local conflict = observed:read().permission_requests_by_id['per-conflict'].preview
        assert.equals('other.lua', conflict.path)
        assert.is_nil(conflict.diff)
        stop()
      end
    )
  end

  it('marks a known inbox item not_pending when an authority snapshot omits it', function()
    local value = connection()
    local inbox_page = Promise.new()
    local streams = install_operations(value, {
      list_inbox = function()
        return inbox_page
      end,
    })
    local observed = value:observe({ id = 'ses-main' })
    local stop = observed:watch({ 'inbox' }, function() end)
    emit(
      streams[1],
      event('ses-main', 'session.inbox.enqueued', {
        inboxID = 'msg-known',
        item = { type = 'user', payload = { text = 'x' }, delivery = 'queue' },
      }, 10)
    )
    inbox_page:resolve({})
    flush(function()
      return observed:read().inbox.items_by_id['msg-known']
        and observed:read().inbox.items_by_id['msg-known'].status == 'not_pending'
    end)
    emit(streams[1], event('ses-main', 'session.viewed', { idle = 20 }, 20))
    flush()
    assert.equals('not_pending', observed:read().inbox.items_by_id['msg-known'].status)
    assert.equals('current', observed:read().sync.inbox.state)
    stop()
  end)

  it('requests a reply without requiring the caller to watch messages or manage admissions', function()
    local value = connection()
    local streams = install_operations(value, {
      submit = function()
        return resolved({ id = 'msg-local', delivery = 'queue' })
      end,
    })
    local observed = value:observe({ id = 'ses-main' })
    local request = observed:request_reply({ text = 'hello', context = {}, files = {}, agents = {} })
    flush(function()
      return observed:read().sync.messages.state == 'current' and observed._v2_admissions['msg-local'] ~= nil
    end)

    emit(
      streams[1],
      event('ses-main', 'session.inbox.enqueued', {
        inboxID = 'msg-local',
        item = { type = 'user', payload = { text = 'hello' }, delivery = 'queue' },
      }, 11)
    )
    emit(streams[1], event('ses-main', 'session.inbox.delivered', { inboxID = 'msg-local' }, 12))
    emit(streams[1], event('ses-main', 'session.execution.started', {}, 13))
    emit(
      streams[1],
      event('ses-main', 'session.step.started', {
        assistantMessageID = 'reply-1',
        agent = 'build',
      }, 14)
    )
    emit(
      streams[1],
      event('ses-main', 'session.text.started', {
        assistantMessageID = 'reply-1',
        ordinal = 0,
      }, 15)
    )
    emit(
      streams[1],
      event('ses-main', 'session.text.ended', {
        assistantMessageID = 'reply-1',
        ordinal = 0,
        text = 'local answer = true',
      }, 16)
    )
    emit(
      streams[1],
      event('ses-main', 'session.step.ended', {
        assistantMessageID = 'reply-1',
        finish = 'stop',
      }, 17)
    )
    emit(streams[1], event('ses-main', 'session.execution.succeeded', {}, 18))

    local reply = request.promise:wait()
    assert.equals('reply-1', reply.id)
    assert.equals('local answer = true', reply.content[1].text)
    assert.is_false(observed:_watches('messages'))
  end)

  it('releases the message subscription when a reply request is cancelled', function()
    local value = connection()
    install_operations(value, {
      submit = function()
        return Promise.new()
      end,
    })
    local observed = value:observe({ id = 'ses-main' })
    local request = observed:request_reply({ text = 'hello', context = {}, files = {}, agents = {} })
    assert.is_true(observed:_watches('messages'))

    request.stop('Cancelled by caller')

    local ok, err = pcall(function()
      request.promise:wait()
    end)
    assert.is_false(ok)
    assert.matches('Cancelled by caller', tostring(err))
    assert.is_false(observed:_watches('messages'))
  end)

  it('passes selected agent and model through the V2 submit operation', function()
    local value = connection()
    local sent
    install_operations(value, {
      submit = function(_, _, input)
        sent = input
        return resolved({ id = 'msg-local', delivery = 'queue' })
      end,
    })
    local observed = value:observe({ id = 'ses-main' })
    local input = { text = 'hello', context = {}, files = {}, agents = {} }

    observed:submit(input, { mode = 'plan', model = 'provider/selected-model', variant = 'high' }):wait()

    assert.equals('plan', sent.agent)
    assert.same({ providerID = 'provider', modelID = 'selected-model' }, sent.model)
    assert.equals('high', sent.variant)
    assert.is_nil(input.agent)
    assert.is_nil(input.model)
  end)

  it('passes selected agent without a selected model through V2 submit', function()
    local value = connection()
    local sent
    install_operations(value, {
      submit = function(_, _, input)
        sent = input
        return resolved({ id = 'msg-local', delivery = 'queue' })
      end,
    })
    local observed = value:observe({ id = 'ses-main' })

    observed:submit({ text = 'hello', context = {}, files = {}, agents = {} }, { mode = 'plan' }):wait()

    assert.equals('plan', sent.agent)
    assert.is_nil(sent.model)
  end)

  it('correlates only a delivered admission with the following same-session terminal', function()
    local value = connection()
    local admission = Promise.new()
    local streams = install_operations(value, {
      submit = function()
        return admission
      end,
    })
    local observed = value:observe({ id = 'ses-main' })
    local stop = observed:watch({ 'inbox', 'execution' }, function() end)
    emit(streams[1], event('ses-other', 'session.execution.succeeded', {}, 10))
    emit(streams[1], event('ses-main', 'session.execution.succeeded', {}, 11))
    emit(
      streams[1],
      event('ses-main', 'session.inbox.enqueued', {
        inboxID = 'msg-local',
        item = { type = 'user', payload = { text = 'hello' }, delivery = 'queue' },
      }, 11)
    )
    emit(streams[1], event('ses-main', 'session.inbox.delivered', { inboxID = 'msg-local' }, 12))
    emit(streams[1], event('ses-main', 'session.execution.started', {}, 13))
    emit(streams[1], event('ses-main', 'session.execution.succeeded', {}, 14))
    local submitted = observed:submit({ text = 'hello', context = {}, files = {}, agents = {}, skills = {} })
    admission:resolve({ id = 'msg-local', delivery = 'queue' })
    local result = submitted:wait()
    assert.equals('accepted', result.kind)
    assert.equals('msg-local', result.input.id)
    assert.equals('delivered', observed:read().inbox.items_by_id['msg-local'].status)
    local idle = result.completion:wait()
    assert.equals('session_idle', idle.kind)
    assert.equals('succeeded', idle.outcome)
    assert.equals(14, idle.idle_at)
    assert.is_nil(observed._v2_admissions['msg-local'])
    stop()
  end)

  it('keeps completion attached to each of two queued submissions', function()
    local value = connection()
    local next_id = 0
    local streams = install_operations(value, {
      submit = function()
        next_id = next_id + 1
        return resolved({ id = 'msg-' .. next_id, delivery = 'queue' })
      end,
    })
    local observed = value:observe({ id = 'ses-main' })
    local first = observed:submit({ text = 'first' }):wait()
    local second = observed:submit({ text = 'second' }):wait()
    emit(streams[1], event('ses-main', 'session.inbox.delivered', { inboxID = 'msg-1' }, 10))
    emit(streams[1], event('ses-main', 'session.execution.started', {}, 11))
    emit(streams[1], event('ses-main', 'session.execution.succeeded', {}, 12))
    assert.equals(12, first.completion:wait().idle_at)
    assert.is_false(second.completion:is_resolved())
    assert.equals(observed, value.observations['ses-main'])
    emit(streams[1], event('ses-main', 'session.inbox.delivered', { inboxID = 'msg-2' }, 20))
    emit(streams[1], event('ses-main', 'session.execution.started', {}, 21))
    emit(streams[1], event('ses-main', 'session.execution.failed', { error = { message = 'failed' } }, 22))
    assert.equals('failed', second.completion:wait().outcome)
    assert.equals('succeeded', first.completion:wait().outcome)
    assert.same({}, observed._v2_admissions)
    assert.is_nil(value.observations['ses-main'])
    assert.is_true(streams[1].handle.stopped)
  end)

  it('does not count non-user inbox deliveries as competing prompt inputs', function()
    local value = connection()
    local streams = install_operations(value, {
      submit = function()
        return resolved({ id = 'msg-local', delivery = 'queue' })
      end,
    })
    local observed = value:observe({ id = 'ses-main' })
    local accepted = observed:submit({ text = 'hello' }):wait()
    emit(
      streams[1],
      event('ses-main', 'session.inbox.enqueued', {
        inboxID = 'synthetic-1',
        item = { type = 'synthetic', payload = { text = 'agent changed' }, delivery = 'queue' },
      }, 10)
    )
    emit(streams[1], event('ses-main', 'session.inbox.delivered', { inboxID = 'synthetic-1' }, 11))
    emit(streams[1], event('ses-main', 'session.inbox.delivered', { inboxID = 'msg-local' }, 12))
    emit(streams[1], event('ses-main', 'session.execution.started', {}, 13))
    emit(streams[1], event('ses-main', 'session.execution.succeeded', {}, 14))

    assert.equals('succeeded', accepted.completion:wait().outcome)
    assert.is_nil(observed._v2_delivered['synthetic-1'])
  end)

  it('rejects ambiguous delivery even when the HTTP admissions arrive after the terminal', function()
    local value = connection()
    local http = { Promise.new(), Promise.new() }
    local next_id = 0
    local streams = install_operations(value, {
      submit = function()
        next_id = next_id + 1
        return http[next_id]
      end,
    })
    local observed = value:observe({ id = 'ses-main' })
    local first = observed:submit({ text = 'first' })
    local second = observed:submit({ text = 'second' })
    emit(streams[1], event('ses-main', 'session.inbox.delivered', { inboxID = 'msg-1' }, 10))
    emit(streams[1], event('ses-main', 'session.inbox.delivered', { inboxID = 'msg-2' }, 11))
    emit(streams[1], event('ses-main', 'session.execution.started', {}, 12))
    emit(streams[1], event('ses-main', 'session.execution.succeeded', {}, 13))
    http[1]:resolve({ id = 'msg-1' })
    http[2]:resolve({ id = 'msg-2' })
    for _, pending in ipairs({ first, second }) do
      local accepted = pending:wait()
      local ok, err = pcall(function()
        accepted.completion:wait()
      end)
      assert.is_false(ok)
      assert.matches('multiple inputs delivered', tostring(err))
    end
    assert.same({}, observed._v2_admissions)
    assert.is_nil(value.observations['ses-main'])
  end)

  it('retains each delivery outcome when several executions finish before HTTP returns', function()
    local value = connection()
    local http = { Promise.new(), Promise.new() }
    local next_id = 0
    local streams = install_operations(value, {
      submit = function()
        next_id = next_id + 1
        return http[next_id]
      end,
    })
    local observed = value:observe({ id = 'ses-main' })
    local first = observed:submit({ text = 'first' })
    local second = observed:submit({ text = 'second' })
    emit(streams[1], event('ses-main', 'session.inbox.delivered', { inboxID = 'msg-1' }, 10))
    emit(streams[1], event('ses-main', 'session.execution.started', {}, 11))
    emit(streams[1], event('ses-main', 'session.execution.succeeded', {}, 12))
    emit(streams[1], event('ses-main', 'session.inbox.delivered', { inboxID = 'msg-2' }, 20))
    emit(streams[1], event('ses-main', 'session.execution.started', {}, 21))
    emit(streams[1], event('ses-main', 'session.execution.interrupted', {}, 22))
    http[2]:resolve({ id = 'msg-2' })
    local second_result = second:wait().completion:wait()
    http[1]:resolve({ id = 'msg-1' })
    local first_result = first:wait().completion:wait()
    assert.equals('succeeded', first_result.outcome)
    assert.equals(12, first_result.idle_at)
    assert.equals('interrupted', second_result.outcome)
    assert.equals(22, second_result.idle_at)
    assert.is_nil(value.observations['ses-main'])
  end)

  it('cancels local waiting without releasing another submission', function()
    local value = connection()
    local next_id = 0
    local streams = install_operations(value, {
      submit = function()
        next_id = next_id + 1
        return resolved({ id = 'msg-' .. next_id })
      end,
    })
    local observed = value:observe({ id = 'ses-main' })
    local first = observed:submit({ text = 'first' }):wait()
    local second = observed:submit({ text = 'second' }):wait()
    first.stop('cancelled')
    first.stop('cancelled again')
    assert.has_error(function()
      first.completion:wait()
    end, 'cancelled')
    assert.is_false(second.completion:is_resolved())
    assert.is_nil(observed._v2_admissions['msg-1'])
    assert.is_not_nil(observed._v2_admissions['msg-2'])
    assert.is_false(streams[1].handle.stopped)
    second.stop()
    assert.equals(0, observed._local_operations)
    assert.is_nil(value.observations['ses-main'])
    assert.is_true(streams[1].handle.stopped)
  end)

  it('releases a cancelled reply admission that arrives after cancellation', function()
    local value = connection()
    local http = Promise.new()
    local streams = install_operations(value, {
      submit = function()
        return http
      end,
    })
    local observed = value:observe({ id = 'ses-main' })
    local request = observed:request_reply({ text = 'hello' })
    request.stop('cancelled')
    http:resolve({ id = 'msg-local' })
    assert.has_error(function()
      request.promise:wait()
    end, 'cancelled')
    flush(function()
      return observed._local_operations == 0
    end)
    assert.same({}, observed._v2_admissions)
    assert.is_nil(value.observations['ses-main'])
    assert.is_true(streams[1].handle.stopped)
  end)

  it('rejects an active admission waiter when event continuity is lost', function()
    local value = connection()
    local streams = install_operations(value, {
      submit = function()
        return resolved({ id = 'msg-local', delivery = 'queue' })
      end,
    })
    local observed = value:observe({ id = 'ses-main' })
    local stop = observed:watch({ 'inbox', 'execution' }, function() end)
    local accepted = observed:submit({ text = 'hello' }):wait()
    emit(streams[1], event('ses-main', 'session.inbox.delivered', { inboxID = 'msg-local' }, 10))
    emit(streams[1], event('ses-main', 'session.execution.started', {}, 11))
    local waiting = accepted.completion

    streams[1].disconnect('network lost')
    local ok, err = pcall(function()
      waiting:wait()
    end)
    assert.is_false(ok)
    assert.matches('admission_unknown', tostring(err))
    assert.is_nil(observed._v2_admissions['msg-local'])
    stop()
  end)

  it('does not assign a post-gap terminal to an admission that became unknown', function()
    local value = connection()
    local streams = install_operations(value, {
      submit = function()
        return resolved({ id = 'msg-local', delivery = 'queue' })
      end,
    })
    local observed = value:observe({ id = 'ses-main' })
    local stop = observed:watch({ 'inbox', 'execution' }, function() end)
    local accepted = observed:submit({ text = 'hello' }):wait()
    emit(streams[1], event('ses-main', 'session.inbox.delivered', { inboxID = 'msg-local' }, 10))
    emit(streams[1], event('ses-main', 'session.execution.started', {}, 11))
    streams[1].disconnect('network lost')
    flush(function()
      return #streams == 2
    end)
    emit(streams[2], event('ses-main', 'session.execution.succeeded', {}, 12))

    local ok, err = pcall(function()
      accepted.completion:wait()
    end)
    assert.is_false(ok)
    assert.matches('admission_unknown', tostring(err))
    assert.is_nil(observed._v2_admissions['msg-local'])
    stop()
  end)

  it('marks an admission unknown when the stream disconnects before submit returns', function()
    local value = connection()
    local admission = Promise.new()
    local streams = install_operations(value, {
      submit = function()
        return admission
      end,
    })
    local observed = value:observe({ id = 'ses-main' })
    local stop = observed:watch({ 'inbox', 'execution' }, function() end)
    local submitted = observed:submit({ text = 'hello' })
    streams[1].disconnect('network lost')
    admission:resolve({ id = 'msg-local', delivery = 'queue' })

    local accepted = submitted:wait()
    assert.equals('accepted', accepted.kind)
    assert.equals('msg-local', accepted.input.id)
    flush(function()
      return #streams == 2
    end)
    emit(streams[2], event('ses-main', 'session.inbox.delivered', { inboxID = 'msg-local' }, 10))
    emit(streams[2], event('ses-main', 'session.execution.started', {}, 11))
    emit(streams[2], event('ses-main', 'session.execution.succeeded', {}, 12))

    local ok, err = pcall(function()
      accepted.completion:wait()
    end)
    assert.is_false(ok)
    assert.matches('admission_unknown', tostring(err))
    assert.is_nil(observed._v2_admissions['msg-local'])
    stop()
  end)

  it('rejects an active admission waiter when its Connection closes', function()
    local value = connection()
    local streams = install_operations(value, {
      submit = function()
        return resolved({ id = 'msg-local', delivery = 'queue' })
      end,
    })
    local observed = value:observe({ id = 'ses-main' })
    observed:watch({ 'inbox', 'execution' }, function() end)
    local accepted = observed:submit({ text = 'hello' }):wait()
    emit(streams[1], event('ses-main', 'session.inbox.delivered', { inboxID = 'msg-local' }, 10))
    local waiting = accepted.completion

    value:close():wait()
    local ok, err = pcall(function()
      waiting:wait()
    end)
    assert.is_false(ok)
    assert.matches('admission_unknown', tostring(err))
    assert.same({}, value.observations)
  end)

  it('removes each admission record when its completion settles', function()
    local value = connection()
    local next_id = 0
    local streams = install_operations(value, {
      submit = function()
        next_id = next_id + 1
        return resolved({ id = 'msg-' .. next_id, delivery = 'queue' })
      end,
    })
    local observed = value:observe({ id = 'ses-main' })
    local stop = observed:watch({ 'inbox', 'execution' }, function() end)

    for index = 1, 2 do
      local id = 'msg-' .. index
      local accepted = observed:submit({ text = id }):wait()
      emit(streams[1], event('ses-main', 'session.inbox.delivered', { inboxID = id }, index * 10))
      emit(streams[1], event('ses-main', 'session.execution.started', {}, index * 10 + 1))
      emit(streams[1], event('ses-main', 'session.execution.succeeded', {}, index * 10 + 2))
      local idle = accepted.completion:wait()
      assert.equals('session_idle', idle.kind)
      assert.equals('succeeded', idle.outcome)
      assert.is_nil(observed._v2_admissions[id])
    end

    assert.same({}, observed._v2_admissions)
    stop()
  end)

  it('keeps an unwatched accepted admission alive until its execution becomes terminal', function()
    local value = connection()
    local streams = install_operations(value, {
      submit = function()
        return resolved({ id = 'msg-local', delivery = 'queue' })
      end,
    })
    local observed = value:observe({ id = 'ses-main' })

    local accepted = observed:submit({ text = 'hello' }):wait()
    assert.equals('accepted', accepted.kind)
    assert.equals(observed, value.observations['ses-main'])
    assert.is_false(streams[1].handle.stopped)

    emit(streams[1], event('ses-main', 'session.inbox.delivered', { inboxID = 'msg-local' }, 10))
    emit(streams[1], event('ses-main', 'session.execution.started', {}, 11))
    emit(streams[1], event('ses-main', 'session.execution.succeeded', {}, 12))
    assert.is_nil(value.observations['ses-main'])
    assert.is_true(streams[1].handle.stopped)

    local idle = accepted.completion:wait()
    assert.equals('session_idle', idle.kind)
    assert.equals('succeeded', idle.outcome)
    assert.is_nil(observed._v2_admissions['msg-local'])
  end)

  it('recovers a disconnected stream and keeps a failed authority read visible', function()
    local value = connection()
    local reads = 0
    local streams = install_operations(value, {
      list_messages = function()
        reads = reads + 1
        if reads == 1 then
          return resolved({ data = { user('msg-first', 'first') }, cursor = {} })
        end
        return Promise.new():reject('snapshot unavailable')
      end,
    })
    local observed = value:observe({ id = 'ses-main' })
    local stop = observed:watch({ 'messages' }, function() end)
    flush(function()
      return observed:read().sync.messages.state == 'current'
    end)
    streams[1].disconnect('network lost')
    flush(function()
      return #streams == 2
        and observed:read().sync.messages.state == 'error'
        and observed:read().sync.messages.error.message:match('snapshot unavailable') ~= nil
    end)
    assert.is_true(streams[1].handle.stopped)
    assert.equals('operation', observed:read().sync.messages.error.kind)
    stop()
    assert.is_true(streams[2].handle.stopped)
  end)

  it('rejects exclusive waiting when a session starts a second execution before terminal', function()
    local value = connection()
    local streams = install_operations(value, {
      submit = function()
        return resolved({ id = 'msg-local' })
      end,
    })
    local observed = value:observe({ id = 'ses-main' })
    local stop = observed:watch({ 'inbox', 'execution' }, function() end)
    local accepted = observed:submit({ text = 'x' }):wait()
    emit(streams[1], event('ses-main', 'session.inbox.delivered', { inboxID = 'msg-local' }, 10))
    emit(streams[1], event('ses-main', 'session.execution.started', {}, 11))
    emit(streams[1], event('ses-main', 'session.execution.started', {}, 12))
    local ok, err = pcall(function()
      accepted.completion:wait()
    end)
    assert.is_false(ok)
    assert.matches('overlapping execution horizons', tostring(err))
    assert.equals('unknown', observed:read().execution.activity)
    stop()
  end)

  it('keeps the first execution terminal until a new execution starts', function()
    local value = connection()
    local streams = install_operations(value)
    local observed = value:observe({ id = 'ses-main' })
    local stop = observed:watch({ 'execution' }, function() end)
    emit(streams[1], event('ses-main', 'session.execution.started', {}, 10))
    emit(streams[1], event('ses-main', 'session.execution.succeeded', {}, 11))
    emit(
      streams[1],
      event('ses-main', 'session.execution.failed', {
        error = { name = 'LateError', message = 'duplicate', retryable = false },
      }, 12)
    )
    assert.equals('succeeded', observed:read().execution.last_outcome)
    assert.equals(11, observed:read().execution.last_idle)

    emit(streams[1], event('ses-main', 'session.execution.started', {}, 13))
    emit(
      streams[1],
      event('ses-main', 'session.execution.failed', {
        error = { name = 'Error', message = 'failed', retryable = false },
      }, 14)
    )
    assert.equals('failed', observed:read().execution.last_outcome)
    assert.same({ type = 'Error', message = 'failed', retryable = false }, observed:read().execution.error)
    emit(streams[1], event('ses-main', 'session.execution.started', {}, 15))
    assert.is_nil(observed:read().execution.error)
    stop()
  end)

  it('does not treat an active-session snapshot as a second started event', function()
    local value = connection()
    local streams = install_operations(value, {
      list_active_sessions = function()
        return resolved({ ['ses-main'] = { type = 'running' } })
      end,
    })
    local observed = value:observe({ id = 'ses-main' })
    local stop = observed:watch({ 'execution' }, function() end)
    flush(function()
      return observed:read().sync.execution.state == 'current'
    end)
    emit(streams[1], event('ses-main', 'session.execution.started', {}, 10))
    assert.equals('running', observed:read().execution.activity)
    assert.is_false(observed._v2_horizon_ambiguous)
    stop()
  end)

  it('publishes revert state immediately for undo and redo rendering', function()
    local value = connection()
    local calls = {}
    install_operations(value, {
      revert_message = function(_, session_id, location, input, path_map, reverse_path_map)
        calls[#calls + 1] = { 'revert', session_id, location, input, path_map, reverse_path_map }
        return resolved({ messageID = input.messageID, diff = '--- a/a.lua\n+++ b/a.lua' })
      end,
      unrevert_messages = function(_, session_id)
        calls[#calls + 1] = { 'unrevert', session_id }
        return resolved(true)
      end,
    })
    local observed = value:observe({ id = 'ses-main' })
    local notifications = 0
    local stop = observed:watch({ 'session' }, function()
      notifications = notifications + 1
    end)
    flush(function()
      return observed:read().sync.session.state == 'current'
    end)
    local before = notifications

    local revert = observed:revert_message('msg-1'):wait()
    assert.equals('msg-1', revert.messageID)
    assert.equals('msg-1', observed:read().session.revert.messageID)
    assert.equals(before + 1, notifications)

    assert.is_true(observed:unrevert_messages():wait())
    assert.is_nil(observed:read().session.revert)
    assert.equals(before + 2, notifications)
    assert.same({
      { 'revert', 'ses-main', nil, { messageID = 'msg-1' }, nil, nil },
      { 'unrevert', 'ses-main' },
    }, calls)
    stop()
  end)

  it('validates permission and form replies before calling their operations', function()
    local value = connection()
    local calls = {}
    local streams, operations = install_operations(value, {
      reply_permission = function(_, session_id, request_id, answer)
        calls[#calls + 1] = { 'permission', session_id, request_id, answer }
        return resolved(true)
      end,
      reply_question = function(_, session_id, request_id, answer)
        calls[#calls + 1] = { 'question', session_id, request_id, answer }
        return resolved(true)
      end,
      cancel_question = function(_, session_id, request_id)
        calls[#calls + 1] = { 'cancel', session_id, request_id }
        return resolved(true)
      end,
      interrupt = function(_, session_id)
        calls[#calls + 1] = { 'interrupt', session_id }
        return resolved(true)
      end,
    })
    local observed = value:observe({ id = 'ses-main' })
    local stop = observed:watch({ 'permissions', 'questions' }, function() end)
    flush(function()
      return observed:read().sync.permissions.state == 'current' and observed:read().sync.questions.state == 'current'
    end)
    emit(
      streams[1],
      event('ses-main', 'permission.asked', {
        id = 'per-1',
        action = 'read',
        resources = { '/tmp' },
      })
    )
    emit(streams[1], {
      type = 'form.created',
      created = 12,
      data = {
        form = {
          id = 'frm-1',
          sessionID = 'ses-main',
          title = 'Choose',
          fields = { { key = 'count', type = 'integer', required = true } },
        },
      },
    })
    assert.has_error(function()
      observed:reply_permission('per-1', { choice = 'session' })
    end, 'V2 observation: invalid permission answer')
    assert.has_error(function()
      observed:reply_question('frm-1', { count = 1.5 })
    end, 'V2 observation: invalid answer for question field count')
    assert.same({}, calls)

    observed:reply_permission('per-1', { choice = 'once', message = 'needed' }):wait()
    observed:reply_question('frm-1', { count = 2 }):wait()
    observed:reject_question('frm-1'):wait()
    observed:interrupt():wait()
    assert.same({
      { 'permission', 'ses-main', 'per-1', { reply = 'once', message = 'needed' } },
      { 'question', 'ses-main', 'frm-1', { count = 2 } },
      { 'cancel', 'ses-main', 'frm-1' },
      { 'interrupt', 'ses-main' },
    }, calls)
    assert.equals(operations, value.operations)
    stop()
  end)
end)
