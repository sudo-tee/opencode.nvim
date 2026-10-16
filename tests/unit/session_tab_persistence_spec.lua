local state = require('opencode.state')
local tabs = state.session_tabs
local config = require('opencode.config')
local server_job = require('opencode.server_job')
local service = require('opencode.services.session_tab_persistence')
local Promise = require('opencode.promise')
local stub = require('luassert.stub')

describe('session tab persistence', function()
  local original_state
  local original_enabled
  local original_server
  local temporary
  local path_stub
  local server_stub
  local connection
  local project_id

  local function restart()
    tabs.reset()
    state.store.set_raw('active_session', nil)
    state.store.set_raw('windows', nil)
    state.store.set_raw('_hidden_buffers', nil)
    state.store.set_raw('current_cwd', vim.fn.getcwd())
    tabs.setup()
    service.setup()
  end

  before_each(function()
    vim.wait(20)
    original_state = vim.deepcopy(state.store.state())
    original_enabled = config.ui.restore_tabs_on_startup
    original_server = vim.deepcopy(config.server)
    config.ui.restore_tabs_on_startup = true
    temporary = vim.fn.tempname()
    vim.fn.mkdir(temporary, 'p')
    path_stub = stub(vim.fn, 'stdpath', function()
      return temporary
    end)
    connection = { operations = {} }
    project_id = 'test-project'
    connection.operations.get_current_project = function()
      return Promise.new():resolve({ id = project_id })
    end
    connection.operations.get_session = function(_, id, location)
      return Promise.new():resolve({ id = id, title = id, location = location })
    end
    server_stub = stub(server_job, 'ensure_server', function()
      return Promise.new():resolve(connection)
    end)
    restart()
  end)

  ---@param background? boolean
  local function restore(background)
    local restoring = service.restore(background == true)
    if restoring then
      restoring:wait()
    end
  end

  after_each(function()
    tabs.reset()
    vim.api.nvim_del_augroup_by_name('OpencodeSessionTabPersistence')
    path_stub:revert()
    server_stub:revert()
    vim.fn.delete(temporary, 'rf')
    config.ui.restore_tabs_on_startup = original_enabled
    config.server = original_server
    for key in pairs(state.store.state()) do
      state.store.set_raw(key, nil)
    end
    for key, value in pairs(original_state) do
      state.store.set_raw(key, value)
    end
  end)

  local function save_tabs()
    restore()
    state.session.set_active({ id = 'first', title = 'First' })
    local first = tabs.current()
    first.bound_directory = temporary
    first.bound_editor_cwd = vim.fn.getcwd()
    state.context.set_current_cwd(temporary)
    state.session.set_locked(true)
    local second = tabs.create({ id = 'second', title = 'Second' })
    second.current_cwd = vim.fn.getcwd()
    second.session_locked = false
    tabs.activate(second)
    assert.is_true(service.save())
  end

  local function snapshot_path()
    return vim.fn.glob(temporary .. '/opencode/session-tabs/*.json')
  end

  it('restores order, active tab, directory binding and locks, without runtime UI data', function()
    save_tabs()
    local saved = vim.json.decode(table.concat(vim.fn.readfile(snapshot_path()), '\n'))
    assert.same({ 'first', 'second' }, { saved.tabs[1].session_id, saved.tabs[2].session_id })
    assert.is_nil(saved.tabs[1].windows)
    assert.is_nil(saved.tabs[1].messages)
    assert.is_nil(saved.tabs[1].pending_permissions)
    restart()
    restore()
    local restored = tabs.list()
    assert.equals(2, #restored)
    assert.equals('first', restored[1].active_session.id)
    assert.equals('second', tabs.current().active_session.id)
    assert.equals(temporary, restored[1].bound_directory)
    assert.equals(vim.fn.getcwd(), restored[1].bound_editor_cwd)
    assert.is_true(restored[1].session_locked)
    assert.is_false(restored[2].session_locked)
    assert.is_nil(state.windows)
  end)

  it('restores on first open only, not on setup or subsequent calls', function()
    save_tabs()
    restart()
    assert.equals(1, #tabs.list())
    assert.is_nil(tabs.current().active_session)
    restore()
    tabs.remove(tabs.list()[1])
    restore()
    assert.equals(1, #tabs.list())
  end)

  it('does not read or write snapshots when disabled', function()
    save_tabs()
    local saved = vim.fn.readfile(snapshot_path())
    restart()
    config.ui.restore_tabs_on_startup = false
    restore()
    assert.is_nil(tabs.current().active_session)
    assert.is_true(service.save())
    assert.same(saved, vim.fn.readfile(snapshot_path()))
  end)

  it('does not overwrite snapshots if the panel was never opened', function()
    save_tabs()
    local saved = vim.fn.readfile(snapshot_path())
    restart()
    service.save()
    assert.same(saved, vim.fn.readfile(snapshot_path()))
  end)

  it('shares an in-flight restore and does not overwrite its snapshot on exit', function()
    save_tabs()
    local saved = vim.fn.readfile(snapshot_path())
    restart()
    local lookup = Promise.new()
    connection.operations.get_session = function()
      return lookup
    end
    local first = service.restore(false)
    local second = service.restore(false)
    assert.is_not_nil(first)
    assert.equals(first, second)
    service.save()
    assert.same(saved, vim.fn.readfile(snapshot_path()))
    lookup:resolve({ id = 'first' })
    first:wait()
    assert.is_nil(service.restore(false))
  end)

  it('does not replace a session selected while saved sessions are loading', function()
    save_tabs()
    restart()
    local lookup = Promise.new()
    connection.operations.get_session = function()
      return lookup
    end
    local restoring = service.restore(false)
    state.session.set_active({ id = 'explicit' })
    lookup:resolve({ id = 'first' })
    restoring:wait()
    assert.equals(1, #tabs.list())
    assert.equals('explicit', tabs.current().active_session.id)
  end)

  it('resolves the editor project even without a snapshot', function()
    restore()
    assert.is_nil(tabs.current().active_session)
    assert.stub(server_stub).was_called()
  end)

  it('restores saved tabs behind the current tab for explicit new-session opens', function()
    save_tabs()
    restart()
    local current = tabs.current()
    restore(true)
    local restored = tabs.list()
    assert.equals(3, #restored)
    assert.equals(current, tabs.current())
    assert.is_nil(tabs.current().active_session)
    assert.same({ 'first', 'second' }, { restored[2].active_session.id, restored[3].active_session.id })
  end)

  it('does not restore over existing sessions', function()
    save_tabs()
    restart()
    state.session.set_active({ id = 'explicit' })
    restore()
    assert.equals('explicit', tabs.current().active_session.id)
    assert.equals(1, #tabs.list())
  end)

  it('logs a failed restore, keeps the snapshot and retries on the next open', function()
    save_tabs()
    local saved = vim.fn.readfile(snapshot_path())
    restart()
    server_stub:revert()
    server_stub = stub(server_job, 'ensure_server', function()
      return Promise.new():reject('startup failed')
    end)
    local restoring = service.restore(false)
    assert.is_not_nil(restoring)
    restoring:wait()
    assert.is_false(restoring:is_rejected())
    assert.equals(1, #tabs.list())
    assert.is_true(service.save())
    assert.same(saved, vim.fn.readfile(snapshot_path()))
    server_stub:revert()
    server_stub = stub(server_job, 'ensure_server', function()
      return Promise.new():resolve(connection)
    end)
    restore()
    assert.equals(2, #tabs.list())
  end)

  it('skips deleted sessions and falls back to the first surviving active tab', function()
    save_tabs()
    restart()
    connection.operations.get_session = function(_, id, location)
      if id == 'second' then
        return Promise.new():reject('Not found')
      end
      return Promise.new():resolve({ id = id, location = location })
    end
    restore()
    assert.equals(1, #tabs.list())
    assert.equals('first', tabs.current().active_session.id)
  end)

  it('skips missing directories and preserves the empty fallback tab when none survive', function()
    save_tabs()
    local path = snapshot_path()
    local saved = vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
    for _, entry in ipairs(saved.tabs) do
      entry.directory = temporary .. '/missing'
    end
    vim.fn.writefile({ vim.json.encode(saved) }, path)
    restart()
    restore()
    assert.equals(1, #tabs.list())
    assert.is_nil(tabs.current().active_session)
  end)

  it('isolates different editor directories and configured servers', function()
    assert.are_not.equals(service.path('/one', 'server'), service.path('/two', 'server'))
    save_tabs()
    restart()
    config.server.url = 'http://different-server'
    restore()
    assert.is_nil(tabs.current().active_session)
  end)

  it('ignores corrupt files, invalid schema, other versions and mismatched workspace data', function()
    local path = service.path('/workspace', 'server')
    vim.fn.mkdir(vim.fs.dirname(path), 'p')
    for _, content in ipairs({
      'not json',
      '42',
      '{"version":3,"project":"/workspace","cwd":"/workspace","server":"server","tabs":[],"active_index":0}',
      '{"version":2,"project":"/other","cwd":"/workspace","server":"server","tabs":[],"active_index":0}',
      '{"version":2,"project":"/workspace","cwd":"/workspace","server":"other","tabs":[],"active_index":0}',
      '{"version":2,"project":"/workspace","cwd":"/workspace","server":"server","active_index":0}',
      '{"version":2,"project":"/workspace","cwd":"/workspace","server":"server","tabs":[{}],"active_index":1}',
      '{"version":2,"project":"/workspace","cwd":"/workspace","server":"server","tabs":[],"active_index":0.5}',
    }) do
      vim.fn.writefile({ content }, path)
      assert.is_nil(service.load('/workspace', 'server'))
    end
  end)

  it('keeps the previous snapshot if an atomic write fails', function()
    save_tabs()
    local path = snapshot_path()
    local saved = vim.fn.readfile(path)
    local rename = stub(os, 'rename').returns(nil, 'rename failed')
    local ok = service.save()
    rename:revert()
    assert.is_false(ok)
    assert.same(saved, vim.fn.readfile(path))
    assert.equals('', vim.fn.glob(path .. '.*.tmp'))
  end)

  it('saves the tab set through VimLeavePre and removes closed tabs', function()
    save_tabs()
    tabs.remove(tabs.list()[1])
    vim.api.nvim_exec_autocmds('VimLeavePre', { group = 'OpencodeSessionTabPersistence' })
    restart()
    restore()
    assert.equals(1, #tabs.list())
    assert.equals('second', tabs.current().active_session.id)
  end)

  it('does not resurrect tabs after all tabs were explicitly closed', function()
    save_tabs()
    for _, runtime in ipairs(tabs.list()) do
      tabs.remove(runtime)
    end
    service.save()
    restart()
    restore()
    assert.equals(1, #tabs.list())
    assert.is_nil(tabs.current().active_session)
  end)

  local function enter(project, cwd)
    project_id = project
    local restoring = service.restore(false, nil, cwd)
    if restoring then
      restoring:wait()
    end
  end

  it('switches whole project groups, preserving runtime state and active selection', function()
    save_tabs()
    local first, second = unpack(tabs.list())
    state.ui.set_input_content({ 'unfinished draft' })
    enter('other-project', temporary)
    assert.equals(1, #tabs.list())
    assert.is_nil(tabs.current().active_session)
    assert.equals(second, tabs.get(second.id))
    state.session.set_active({ id = 'other' })
    enter('test-project', vim.fn.getcwd())
    assert.same({ first, second }, tabs.list())
    assert.equals(second, tabs.current())
    assert.same({ 'unfinished draft' }, state.input_content)
    enter('other-project', temporary)
    assert.equals('other', tabs.current().active_session.id)
  end)

  it('does not retarget tabs when subdirectories or worktrees resolve to the same project', function()
    save_tabs()
    local current = tabs.current()
    enter('test-project', temporary)
    assert.equals(current, tabs.current())
    assert.equals(2, #tabs.list())
    assert.equals('second', state.active_session.id)
    assert.equals(1, #vim.fn.glob(temporary .. '/opencode/session-tabs/*.json', false, true))
  end)

  it('writes outgoing groups under their owner and restores both projects after restart', function()
    save_tabs()
    local path_a = snapshot_path()
    local a = vim.json.decode(table.concat(vim.fn.readfile(path_a), '\n'))
    enter('other-project', temporary)
    local path_b = service.path('other-project', a.server)
    assert.equals('test-project', vim.json.decode(table.concat(vim.fn.readfile(path_a), '\n')).project)
    state.session.set_active({ id = 'other', location = { directory = temporary } })
    service.save()
    assert.equals('other-project', vim.json.decode(table.concat(vim.fn.readfile(path_b), '\n')).project)
    restart()
    enter('test-project', vim.fn.getcwd())
    assert.equals(2, #tabs.list())
    enter('other-project', temporary)
    assert.equals('other', state.active_session.id)
    assert.equals(1, #tabs.list())
  end)

  it('isolates configured servers even at the same editor cwd', function()
    save_tabs()
    config.server.url = 'http://another-server'
    restore()
    assert.is_nil(tabs.current().active_session)
    config.server = vim.deepcopy(original_server)
    restore()
    assert.equals('second', state.active_session.id)
  end)

  it('isolates unrelated directories in the global project', function()
    enter('global', '/one')
    state.session.set_active({ id = 'one' })
    enter('global', '/two')
    assert.is_nil(state.active_session)
    enter('global', '/one')
    assert.equals('one', state.active_session.id)
  end)

  it('adopts the editor directory when the first group opens after a cwd change', function()
    enter('test-project', temporary)
    assert.equals(temporary, state.current_cwd)
    assert.equals(temporary, tabs.current().current_cwd)
  end)

  it('ignores out-of-order project resolutions', function()
    restore()
    state.session.set_active({ id = 'initial' })
    local slow = Promise.new()
    connection.operations.get_current_project = function(_, location)
      if location.directory == '/slow' then
        return slow
      end
      return Promise.new():resolve({ id = 'fast-project' })
    end
    local stale = service.restore(false, nil, '/slow')
    service.restore(false, nil, '/fast'):wait()
    state.session.set_active({ id = 'fast' })
    slow:resolve({ id = 'slow-project' })
    stale:wait()
    assert.equals('fast', state.active_session.id)
    assert.equals(1, #tabs.list())
  end)

  it('does not apply stale session lookups after leaving and returning to a group', function()
    save_tabs()
    restart()
    local slow = Promise.new()
    local original_lookup = connection.operations.get_session
    connection.operations.get_session = function()
      return slow
    end
    local stale = service.restore(false)
    assert.is_true(vim.wait(1000, function()
      return #server_stub.calls >= 3
    end))
    enter('other-project', temporary)
    connection.operations.get_session = original_lookup
    enter('test-project', vim.fn.getcwd())
    assert.equals(2, #tabs.list())
    slow:resolve({ id = 'stale' })
    stale:wait()
    assert.equals(2, #tabs.list())
    assert.equals('second', state.active_session.id)
  end)

  it('ignores an outdated snapshot and overwrites it on the next save', function()
    save_tabs()
    local path = snapshot_path()
    local saved = vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
    saved.version, saved.project = 1, nil
    vim.fn.writefile({ vim.json.encode(saved) }, path)
    restart()
    restore()
    assert.is_nil(state.active_session)
    service.save()
    local current = vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
    assert.equals(2, current.version)
    assert.equals('test-project', current.project)
    assert.same({}, current.tabs)
  end)

  it('clears pending requests on parked runtimes without exposing their tabs', function()
    save_tabs()
    local parked = tabs.current()
    tabs.add_pending_permission(parked.id, { id = 'permission', sessionID = 'second' })
    enter('other-project', temporary)
    assert.equals(1, #tabs.list())
    assert.equals(3, #tabs.all())
    require('opencode.ui.session_tab_notifications').clear_permission('permission')
    assert.same({}, parked.pending_prompt_permissions)
  end)

  describe('runtime project orchestration', function()
    local runtime = require('opencode.services.session_runtime')
    local ui = require('opencode.ui.ui')
    local agent_model = require('opencode.services.agent_model')
    local runtime_stubs
    local cwd

    before_each(function()
      cwd = vim.fn.getcwd()
      runtime_stubs = {
        stub(vim.fn, 'getcwd', function()
          return cwd
        end),
        stub(ui, 'prepare_session_tab_switch'),
        stub(ui, 'hide_visible_windows'),
        stub(ui, 'prepare_windows').returns(false),
        stub(ui, 'render_output'),
        stub(ui, 'is_opencode_focused').returns(true),
        stub(agent_model, 'ensure_current_mode').invokes(function()
          state.model.set_mode('build')
          return Promise.new():resolve(true)
        end),
        stub(agent_model, 'initialize_current_model').invokes(function()
          state.model.set_model('test/model')
          return Promise.new():resolve('test/model')
        end),
        stub(agent_model, 'sync_from_server'),
      }
      connection.operations.get_current_project = function(_, location)
        return Promise.new():resolve({ id = location.directory == temporary and 'other-project' or 'test-project' })
      end
      connection.operations.create_session = function(_, location)
        return Promise.new():resolve({ id = 'default-session', location = location })
      end
    end)

    after_each(function()
      for _, item in ipairs(runtime_stubs) do
        item:revert()
      end
    end)

    it('swaps the visible panel instead of retargeting its active tab', function()
      save_tabs()
      local visible = stub(state.ui, 'is_visible').returns(true)
      table.insert(runtime_stubs, visible)
      local previous = tabs.current()
      cwd = temporary
      runtime.handle_directory_change(cwd):wait()
      assert.equals('default-session', state.active_session.id)
      assert.equals(temporary, state.active_session.location.directory)
      assert.equals(1, #tabs.list())
      assert.equals('second', previous.active_session.id)
      assert.stub(ui.hide_visible_windows).was_called(1)
      assert.stub(ui.prepare_windows).was_called(1)
      cwd = vim.uv.cwd()
      runtime.handle_directory_change(cwd):wait()
      assert.equals(previous, tabs.current())
      assert.equals('second', state.active_session.id)
    end)

    it('creates a default session on first open without a snapshot and reuses it on reopen', function()
      cwd = temporary
      local create = stub(connection.operations, 'create_session').invokes(function(_, location)
        return Promise.new():resolve({ id = 'fresh', location = location })
      end)
      table.insert(runtime_stubs, create)
      runtime.open({ new_session = false }):wait()
      assert.equals('fresh', state.active_session.id)
      assert.equals(temporary, state.active_session.location.directory)
      assert.equals(1, #tabs.list())
      runtime.open({ new_session = false }):wait()
      assert.stub(create).was_called(1)
    end)

    it('defers default-session creation for a hidden incoming group until the panel opens', function()
      save_tabs()
      table.insert(runtime_stubs, stub(state.ui, 'is_visible').returns(false))
      cwd = temporary
      runtime.handle_directory_change(cwd):wait()
      assert.is_nil(state.active_session)
      runtime.open({ new_session = false }):wait()
      assert.equals('default-session', state.active_session.id)
      assert.equals(temporary, state.active_session.location.directory)
      assert.equals(1, #tabs.list())
    end)

    it('keeps restored sessions without creating an extra default session', function()
      save_tabs()
      restart()
      local create = stub(connection.operations, 'create_session')
      table.insert(runtime_stubs, create)
      runtime.open({ new_session = false }):wait()
      assert.equals('second', state.active_session.id)
      assert.equals(2, #tabs.list())
      assert.stub(create).was_not_called()
    end)

    for _, empty_snapshot in ipairs({ false, true }) do
      it(
        'creates a default session when ' .. (empty_snapshot and 'the snapshot is empty' or 'no saved sessions survive'),
        function()
          save_tabs()
          if empty_snapshot then
            for _, tab in ipairs(tabs.list()) do
              tabs.remove(tab)
            end
            service.save()
          else
            connection.operations.get_session = function()
              return Promise.new():reject('Not found')
            end
          end
          restart()
          runtime.open({ new_session = false }):wait()
          assert.equals('default-session', state.active_session.id)
          assert.equals(1, #tabs.list())
        end
      )
    end

    it('pins a locked group across directory changes and subsequent panel opens', function()
      save_tabs()
      table.insert(runtime_stubs, stub(state.ui, 'is_visible').returns(false))
      runtime.set_session_lock(true)
      cwd = temporary
      runtime.handle_directory_change(cwd):wait()
      runtime.open({ new_session = false, open_action = 'restore_hidden' }):wait()
      assert.equals('second', state.active_session.id)
      assert.equals(2, #tabs.list())
      runtime.set_session_lock(false)
      runtime.open({ new_session = false, open_action = 'restore_hidden' }):wait()
      assert.equals('default-session', state.active_session.id)
      assert.equals(1, #tabs.list())
    end)
  end)
end)
