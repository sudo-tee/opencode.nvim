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
    original_enabled = config.ui.persist_session_tabs
    original_server = vim.deepcopy(config.server)
    config.ui.persist_session_tabs = true
    temporary = vim.fn.tempname()
    vim.fn.mkdir(temporary, 'p')
    path_stub = stub(vim.fn, 'stdpath', function()
      return temporary
    end)
    connection = { operations = {} }
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
    config.ui.persist_session_tabs = original_enabled
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
    config.ui.persist_session_tabs = false
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

  it('returns nothing to wait for without a snapshot', function()
    assert.is_nil(service.restore(false))
    assert.stub(server_stub).was_not_called()
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
      '{"version":2,"cwd":"/workspace","server":"server","tabs":[],"active_index":0}',
      '{"version":1,"cwd":"/other","server":"server","tabs":[],"active_index":0}',
      '{"version":1,"cwd":"/workspace","server":"server","active_index":0}',
      '{"version":1,"cwd":"/workspace","server":"server","tabs":[{}],"active_index":1}',
      '{"version":1,"cwd":"/workspace","server":"server","tabs":[],"active_index":0.5}',
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
end)
