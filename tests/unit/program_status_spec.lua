local service = require('opencode.services.program_status')
local transport = require('opencode.ui.program_status')
local store = require('opencode.state.store')
local tabs = require('opencode.state.session_tabs')
local config = require('opencode.config')

describe('program status', function()
  local saved, options, reports, observations, viewed, connection

  local function observation(id)
    local item = {
      _connection = connection,
      state = {
        session = { id = id, title = id },
        execution = { activity = 'idle' },
        sync = { execution = { state = 'current' } },
        permission_requests_by_id = {},
        question_requests_by_id = {},
      },
      resources = {},
      released = 0,
    }
    function item:read()
      return self.state
    end
    function item:watch(resources, callback)
      self.resources = resources
      self.changed = callback
      return function()
        self.released = self.released + 1
      end
    end
    observations[id] = item
    return item
  end

  local function start()
    service.start(function(record)
      reports[#reports + 1] = vim.deepcopy(record)
    end, function(id)
      return viewed == id
    end)
  end

  local function execution(item, activity, outcome)
    item.state.execution = { activity = activity, last_outcome = outcome }
    item.changed()
  end

  local function last()
    return reports[#reports]
  end

  before_each(function()
    saved = vim.deepcopy(store.state())
    options = vim.deepcopy(config.values)
    service.stop()
    tabs.reset()
    reports, observations, viewed = {}, {}, nil
    connection = {
      is_ready = function()
        return true
      end,
      observe = function(_, session)
        return observations[session.id]
      end,
    }
    store.set_raw('opencode_server', connection)
  end)

  after_each(function()
    service.stop()
    tabs.reset()
    store.set_raw('opencode_server', nil)
    for key, value in pairs(saved) do
      store.set_raw(key, value)
    end
    config.values = options
  end)

  it('watches only open tab sessions, including inactive tabs, not children or tools', function()
    local parent = observation('parent')
    local second = observation('second')
    local child = observation('child')
    local first = tabs.create({ id = 'parent' })
    tabs.create({ id = 'second' })
    start()
    assert.equals(2, #reports)
    assert.same({ 'session', 'execution', 'permissions', 'questions' }, parent.resources)
    assert.same({}, child.resources)
    execution(parent, 'running')
    execution(second, 'running')
    execution(second, 'idle', 'succeeded')
    assert.equals('done', last().state)
    parent.changed()
    assert.equals('working', reports[3].state)
    assert.equals('done', last().state)
    assert.equals('parent', first.active_session.id)
  end)

  it('tracks completion, acknowledgement, failure, cancellation, and retries', function()
    local item = observation('parent')
    local tab = tabs.create({ id = 'parent' })
    start()
    assert.equals('idle', last().state)
    execution(item, 'running')
    assert.equals('working', last().state)
    execution(item, 'retrying')
    assert.equals(2, #reports)
    execution(item, 'idle', 'succeeded')
    assert.equals('done', last().state)
    viewed = tab.id
    service.refresh()
    assert.equals('idle', last().state)
    viewed = nil
    execution(item, 'running')
    execution(item, 'idle', 'failed')
    assert.equals('error', last().state)
    execution(item, 'running')
    execution(item, 'idle', 'interrupted')
    assert.equals('idle', last().state)
  end)

  it('does not announce historical completion or completion already being viewed', function()
    local item = observation('parent')
    item.state.execution.last_outcome = 'succeeded'
    local tab = tabs.create({ id = 'parent' })
    viewed = tab.id
    start()
    assert.equals('idle', last().state)
    execution(item, 'running')
    execution(item, 'idle', 'succeeded')
    assert.equals('idle', last().state)
  end)

  it('keeps legacy V1 idle transitions conservative without explicit outcomes', function()
    local item = observation('legacy')
    tabs.create({ id = 'legacy' })
    start()
    execution(item, 'running')
    execution(item, 'idle')
    assert.equals('idle', last().state)
  end)

  it('reports pending permissions and questions, then resumes owning session state', function()
    local item = observation('parent')
    tabs.create({ id = 'parent' })
    start()
    execution(item, 'running')
    item.state.permission_requests_by_id.p = { status = 'pending' }
    item.changed()
    assert.equals('blocked', last().state)
    assert.equals('permission', last().kind)
    item.state.question_requests_by_id.q = { status = 'pending' }
    item.state.permission_requests_by_id.p.status = 'answered'
    item.changed()
    assert.equals('question', last().kind)
    item.state.question_requests_by_id.q.status = 'answered'
    item.changed()
    assert.equals('working', last().state)
    assert.is_nil(last().kind)
  end)

  it('clears and releases records on tab close, rebinding, disconnect, and stop', function()
    local one, two = observation('one'), observation('two')
    local tab = tabs.create({ id = 'one' })
    start()
    tabs.set_session(tab, { id = 'two' })
    vim.wait(100, function()
      return one.released == 1
    end)
    assert.equals(1, one.released)
    assert.equals('clear', reports[2].state)
    tabs.remove(tab)
    vim.wait(100, function()
      return two.released == 1
    end)
    assert.equals('clear', last().state)
    assert.equals(1, two.released)
    one.changed()
    assert.equals('clear', last().state)
    tabs.create({ id = 'one' })
    service.refresh()
    store.set('opencode_server', nil)
    service.refresh()
    assert.equals('clear', last().state)
    store.set('opencode_server', connection)
    service.refresh()
    service.stop()
    assert.equals('clear', last().state)
    local count = #reports
    service.refresh()
    assert.equals(count, #reports)
  end)

  for _, outcome in ipairs({ 'succeeded', 'failed' }) do
    it('preserves unseen ' .. outcome .. ' results through disconnect and reconnect', function()
      local item = observation('parent')
      tabs.create({ id = 'parent' })
      start()
      execution(item, 'running')
      execution(item, 'idle', outcome)
      local finished = vim.deepcopy(last())
      local count = #reports

      store.set_raw('opencode_server', nil)
      service.refresh()
      assert.equals(1, item.released)
      assert.equals(count, #reports)
      item.changed()
      service.refresh()
      assert.equals(1, item.released)
      assert.equals(count, #reports)

      -- A replacement observation starts without the old execution history.
      local replacement = observation('parent')
      store.set_raw('opencode_server', connection)
      service.refresh()
      assert.same(finished, last())
      assert.same({ 'session', 'execution', 'permissions', 'questions' }, replacement.resources)
      assert.equals(count, #reports)
      execution(item, 'running')
      assert.equals(count, #reports)
      execution(replacement, 'running')
      assert.equals('working', last().state)
    end)
  end

  it('resubscribes when the same observation reconnects', function()
    local item = observation('parent')
    tabs.create({ id = 'parent' })
    start()
    execution(item, 'running')
    execution(item, 'idle', 'succeeded')
    connection.is_ready = function()
      return false
    end
    service.refresh()
    assert.equals('done', last().state)
    assert.equals(1, item.released)
    connection.is_ready = function()
      return true
    end
    service.refresh()
    execution(item, 'running')
    assert.equals('working', last().state)
    service.stop()
    assert.equals(2, item.released)
  end)

  it('clears a disconnected result when viewed, rebound, closed, or stopped', function()
    for _, action in ipairs({ 'view', 'rebind', 'close', 'stop' }) do
      store.set_raw('opencode_server', connection)
      local item = observation('parent-' .. action)
      local tab = tabs.create({ id = 'parent-' .. action })
      start()
      execution(item, 'running')
      execution(item, 'idle', 'failed')
      store.set_raw('opencode_server', nil)
      service.refresh()
      assert.equals('error', last().state)

      if action == 'view' then
        viewed = tab.id
      elseif action == 'rebind' then
        tabs.set_session(tab, { id = 'other' })
      elseif action == 'close' then
        tabs.remove(tab)
      else
        service.stop()
      end
      service.refresh()
      assert.same({ id = tab.id, state = 'clear' }, last())
      assert.equals(1, item.released)
      service.stop()
      tabs.reset()
      viewed = nil
    end
  end)

  it('clears blocked records on disconnect without reporting successful completion', function()
    local item = observation('parent')
    tabs.create({ id = 'parent' })
    start()
    execution(item, 'running')
    item.state.question_requests_by_id.q = { status = 'pending' }
    item.changed()
    assert.equals('blocked', last().state)
    store.set_raw('opencode_server', nil)
    service.refresh()
    assert.equals('clear', last().state)
    assert.equals(1, item.released)
  end)

  it('clears stale live status during a stream gap and resumes without inventing completion', function()
    local item = observation('parent')
    tabs.create({ id = 'parent' })
    start()
    execution(item, 'running')
    item.state.permission_requests_by_id.p = { status = 'pending' }
    item.changed()
    assert.equals('blocked', last().state)

    item.state.sync.execution.state = 'error'
    item.changed()
    assert.equals('clear', last().state)
    assert.is_nil(last().kind)
    item.state.permission_requests_by_id = {}
    item.state.sync.execution.state = 'current'
    execution(item, 'idle', 'succeeded')
    assert.equals('idle', last().state)
    execution(item, 'running')
    assert.equals('working', last().state)
  end)

  it('keeps finished results through stream errors until viewed or replaced', function()
    local item = observation('parent')
    local tab = tabs.create({ id = 'parent' })
    start()
    execution(item, 'running')
    execution(item, 'idle', 'failed')
    local count = #reports
    item.state.sync.execution.state = 'error'
    item.changed()
    assert.equals(count, #reports)
    assert.equals('error', last().state)
    viewed = tab.id
    service.refresh()
    assert.equals('clear', last().state)
    viewed = nil
    item.state.sync.execution.state = 'current'
    execution(item, 'running')
    assert.equals('working', last().state)
  end)

  it('encodes scoped records and bounded UTF-8 titles without control characters', function()
    local sequence =
      transport.encode({ id = 'tab-1', state = 'blocked', kind = 'question', title = 'Hi\n\027\194\128世界' })
    assert.matches(
      '^\027%]7501;state=blocked:id=opencode%.nvim%-%d+/tab%-1:app=opencode%.nvim:kind=question:',
      sequence
    )
    local encoded = sequence:match('title=([%w+/=]+)')
    assert.equals('Hi   世界', vim.base64.decode(encoded))
    sequence = transport.encode({ id = 'tab-2', state = 'working', title = string.rep('界', 100) })
    encoded = sequence:match('title=([%w+/=]+)')
    assert.equals(string.rep('界', 64), vim.base64.decode(encoded))
    assert.is_true(#sequence < 4096)
    local clear = transport.encode({ id = 'tab-2', state = 'clear' })
    assert.matches('id=opencode%.nvim%-%d+/tab%-2', clear)
  end)

  it('wraps tmux passthrough only when explicitly enabled', function()
    config.values.program_status.tmux = true
    local sequence = transport.encode({ id = 'tab-1', state = 'idle' })
    assert.equals('\027Ptmux;\027\027]7501;', sequence:sub(1, 15))
    assert.equals('\027\027\\\027\\', sequence:sub(-5))
  end)

  it('truncates titles at UTF-8 boundaries for each byte position', function()
    local function encoded_title(text)
      local sequence = transport.encode({ id = 'tab-1', state = 'idle', title = text })
      return vim.base64.decode(sequence:match('title=([%w+/=]*)'))
    end

    assert.equals('', encoded_title(''))
    assert.equals(string.rep('a', 192), encoded_title(string.rep('a', 193)))
    for _, char in ipairs({ 'é', '界', '😀' }) do
      for remaining = 0, #char do
        local prefix = string.rep('a', 192 - remaining)
        local expected = remaining == #char and prefix .. char or prefix
        assert.equals(expected, encoded_title(prefix .. char .. 'suffix'))
      end
    end
  end)

  it('does not subscribe or emit when disabled', function()
    local item = observation('parent')
    tabs.create({ id = 'parent' })
    config.values.program_status.enabled = false
    transport.setup()
    assert.same({}, item.resources)
    assert.same({}, reports)
  end)

  it('sends terminal reports, acknowledges focus, and clears on editor exit', function()
    local item = observation('parent')
    local tab = tabs.create({ id = 'parent' })
    store.set_raw('active_session_tab', tab.id)
    store.set_raw('is_opencode_focused', true)
    store.set_raw('windows', { output_win = vim.api.nvim_get_current_win() })
    config.values.program_status.enabled = true
    local original = vim.api.nvim_ui_send
    local original_has = vim.fn.has
    local sequences = {}
    vim.fn.has = function(feature)
      return feature == 'nvim-0.12' and 1 or original_has(feature)
    end
    vim.api.nvim_ui_send = function(sequence)
      sequences[#sequences + 1] = sequence
    end
    local ok, err = pcall(function()
      transport.setup()
      execution(item, 'running')
      vim.api.nvim_exec_autocmds('FocusLost', { group = 'OpencodeProgramStatus' })
      execution(item, 'idle', 'succeeded')
      assert.matches('state=done:', sequences[#sequences])
      vim.api.nvim_exec_autocmds('FocusGained', { group = 'OpencodeProgramStatus' })
      assert.matches('state=idle:', sequences[#sequences])
      vim.api.nvim_exec_autocmds('VimLeavePre', { group = 'OpencodeProgramStatus' })
      assert.matches('state=clear:', sequences[#sequences])
      local count = #sequences
      item.changed()
      assert.equals(count, #sequences)
    end)
    vim.api.nvim_ui_send = original
    vim.fn.has = original_has
    vim.api.nvim_del_augroup_by_name('OpencodeProgramStatus')
    assert.is_true(ok, err)
  end)

  it('ignores old-session callbacks before scheduled tab rebinding', function()
    local one = observation('one')
    observation('two')
    local tab = tabs.create({ id = 'one' })
    start()
    execution(one, 'running')
    local count = #reports
    tabs.set_session(tab, { id = 'two' })
    execution(one, 'idle', 'succeeded')
    assert.equals(count, #reports)
  end)

  it('routes real V2 execution events without treating child completion as parent completion', function()
    local Promise = require('opencode.promise')
    local server = require('opencode.opencode_server').from_custom('http://v2.test')
    server.protocol = 'v2'
    server.server_identity = { version = '2.0.1' }
    server.credential = { username = 'opencode' }
    server:mark_ready()
    local chunk
    server.operations = {
      subscribe_events = function(owner, on_chunk)
        chunk = on_chunk
        local handle = { shutdown = function() end }
        owner:set_stream(handle)
        return handle
      end,
      get_session = function(_, id)
        return Promise.new():resolve({
          id = id,
          projectID = 'project',
          location = { directory = '/project' },
          title = id,
          cost = 0,
          tokens = {},
          time = { created = 1, updated = 2 },
        })
      end,
      list_active_sessions = function()
        return Promise.new():resolve({})
      end,
      list_permissions = function()
        return Promise.new():resolve({})
      end,
      list_questions = function()
        return Promise.new():resolve({})
      end,
    }
    store.set_raw('opencode_server', server)
    tabs.create({ id = 'parent', location = { directory = '/project' } })
    start()
    assert.is_true(vim.wait(1000, function()
      local observed = server.observations.parent:read()
      return chunk ~= nil
        and observed.sync.session.state == 'current'
        and observed.sync.execution.state == 'current'
        and observed.sync.permissions.state == 'current'
        and observed.sync.questions.state == 'current'
    end))
    local function event(id, kind)
      chunk('data: ' .. vim.json.encode({
        id = id .. kind,
        type = kind,
        created = 10,
        data = { sessionID = id },
      }) .. '\n\n')
      vim.wait(20, function()
        return false
      end)
    end
    event('parent', 'session.execution.started')
    assert.equals('working', last().state)
    local count = #reports
    event('child', 'session.execution.succeeded')
    assert.equals(count, #reports)
    assert.equals('working', last().state)
    event('parent', 'session.execution.succeeded')
    assert.equals('done', last().state)
    service.stop()
    server:close('test teardown')
  end)
end)
