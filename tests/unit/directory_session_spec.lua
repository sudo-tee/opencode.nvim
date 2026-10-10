local assert = require('luassert')
local stub = require('luassert.stub')
local Promise = require('opencode.promise')
local state = require('opencode.state')
local runtime = require('opencode.services.session_runtime')
local support = require('tests.unit.services_spec_support')
local config = require('opencode.config')

describe('directory-bound session API', function()
  local saved, open, ensure, connection, directory, original_lock, original_path_map, original_reverse_path_map

  before_each(function()
    saved = vim.deepcopy(state.store.state())
    original_lock = config.lock_session_to_directory
    original_path_map = config.server.path_map
    original_reverse_path_map = config.server.reverse_path_map
    config.server.path_map = nil
    config.server.reverse_path_map = nil
    config.lock_session_to_directory = false
    state.session_tabs.reset()
    state.ui.set_windows(nil)
    state.session.clear_active()
    state.session.set_locked(false)
    directory = vim.fs.normalize(vim.fn.getcwd() .. '/tests')
    connection = support.mock_connection()
    ensure = stub(require('opencode.server_job'), 'ensure_server').returns(Promise.new():resolve(connection))
    open = stub(runtime, 'open').invokes(function()
      runtime.check_cwd()
      return Promise.new():resolve('ok')
    end)
    connection.operations.create_session = function(_, location, input)
      return Promise.new():resolve({
        id = input.title or 'new',
        title = 'Session',
        location = location,
        time = { updated = 1 },
      })
    end
  end)

  after_each(function()
    open:revert()
    ensure:revert()
    config.lock_session_to_directory = original_lock
    config.server.path_map = original_path_map
    config.server.reverse_path_map = original_reverse_path_map
    state.session_tabs.reset()
    for key in pairs(state.store.state()) do
      state.store.set_raw(key, nil)
    end
    for key, value in pairs(saved) do
      state.store.set_raw(key, value)
    end
  end)

  it('creates in the requested directory without changing Neovim cwd', function()
    local cwd = vim.fn.getcwd()
    local result = require('opencode.api').open_session({ directory = directory, new = true, title = 'work' }):wait()
    assert.equal('work', result.id)
    assert.same({ directory = directory }, result.location)
    assert.equal(directory, state.current_cwd)
    assert.equal(cwd, vim.fn.getcwd())
    assert.equal(directory, state.session_tabs.current().bound_directory)
  end)

  it('restores each tab directory and creates subsequent sessions there', function()
    runtime.open_session({ directory = directory, new = true, title = 'first' }):wait()
    local first = state.session_tabs.current()
    runtime.open_session({ directory = vim.fn.getcwd(), new = true, title = 'second' }):wait()
    runtime.switch_session_tab(first.id):wait()
    assert.equal(directory, state.current_cwd)
    local next_session = runtime.create_new_session('next'):wait()
    assert.equal(directory, next_session.location.directory)
    runtime.open_session_tab('third'):wait()
    assert.equal(directory, state.current_cwd)
    assert.equal(directory, state.session_tabs.current().bound_directory)
  end)

  it('reopens only the latest root session in the exact directory', function()
    connection.operations.list_sessions_project = function(_, location)
      assert.equal(directory, location.directory)
      return Promise.new():resolve({
        { id = 'other', directory = vim.fn.getcwd(), time = { updated = 5 } },
        { id = 'child', directory = directory, parentID = 'root', time = { updated = 4 } },
        { id = 'latest', directory = directory, time = { updated = 3 } },
        { id = 'older', directory = directory, time = { updated = 2 } },
      })
    end
    assert.equal('latest', runtime.open_session({ directory = directory }):wait().id)
    assert.equal(1, #state.session_tabs.list())
    runtime.open_session({ directory = directory, session_id = 'latest' }):wait()
    assert.equal(1, #state.session_tabs.list())
  end)

  it('creates when no root session exists in the directory', function()
    assert.equal('new', runtime.open_session({ directory = directory }):wait().id)
  end)

  it('reuses mapped server sessions without a reverse path map', function()
    local server_directory = '/server/worktree'
    config.server.path_map = function(path)
      return path == directory and server_directory or path
    end
    connection.operations.list_sessions_project = function(_, location, path_map)
      assert.equal(server_directory, path_map(location.directory))
      return Promise.new():resolve({
        { id = 'other', directory = '/server/other', time = { updated = 5 } },
        { id = 'child', directory = server_directory, parentID = 'root', time = { updated = 4 } },
        { id = 'latest', directory = server_directory .. '/.', time = { updated = 3 } },
        { id = 'older', location = { directory = server_directory }, time = { updated = 2 } },
      })
    end
    local create = stub(connection.operations, 'create_session')
    local ok, err = pcall(function()
      local result = runtime.open_session({ directory = directory }):wait()
      assert.equal('latest', result.id)
      assert.equal(directory, result.location.directory)
      runtime.open_session({ directory = directory }):wait()
      assert.equal(1, #state.session_tabs.list())
      assert.stub(create).was_not_called()
    end)
    create:revert()
    assert.is_true(ok, tostring(err))
  end)

  it('accepts mapped explicit sessions but rejects another server directory', function()
    local server_directory = '/server/worktree'
    config.server.path_map = function(path)
      return path == directory and server_directory or path
    end
    connection.operations.get_session = function(_, id)
      return Promise.new():resolve({ id = id, directory = server_directory .. '/.', time = { updated = 1 } })
    end
    assert.equal('mapped', runtime.open_session({ directory = directory, session_id = 'mapped' }):wait().id)
    server_directory = '/server/other'
    config.server.path_map = function(path)
      return path == directory and '/server/worktree' or path
    end
    assert.is_false(pcall(function()
      runtime.open_session({ directory = directory, session_id = 'other' }):wait()
    end))
    assert.equal(1, #state.session_tabs.list())
  end)

  it('reuses normalized local sessions returned by a reverse path map', function()
    config.server.path_map = function()
      return '/server/worktree'
    end
    config.server.reverse_path_map = function()
      return directory .. '/.'
    end
    connection.operations.list_sessions_project = function(_, _, _, reverse_path_map)
      return Promise.new():resolve({
        { id = 'local', location = { directory = reverse_path_map('/server/worktree') }, time = { updated = 1 } },
      })
    end
    assert.equal('local', runtime.open_session({ directory = directory }):wait().id)
    assert.equal(directory, state.current_cwd)
  end)

  it('rejects invalid options and creation errors before activating a tab', function()
    for _, opts in ipairs({
      { directory = directory, new = true, session_id = 'id' },
      { directory = '' },
      { directory = directory .. '/nonexistent' },
    }) do
      assert.is_false(pcall(function()
        runtime.open_session(opts):wait()
      end))
    end
    connection.operations.create_session = function()
      return Promise.new():reject('create failed')
    end
    assert.is_false(pcall(function()
      runtime.open_session({ directory = directory, new = true }):wait()
    end))
    assert.is_nil(state.active_session)
    assert.equal(0, #state.session_tabs.list())
  end)

  it('preserves a locked binding but releases it on unlocked DirChanged', function()
    runtime.open_session({ directory = directory, new = true }):wait()
    runtime.set_session_lock(true)
    runtime.handle_directory_change(vim.fn.getcwd()):wait()
    assert.equal(directory, state.current_cwd)
    runtime.set_session_lock(false)
    runtime.handle_directory_change(vim.fn.getcwd()):wait()
    assert.is_nil(state.session_tabs.current().bound_directory)
    assert.equal(vim.fn.getcwd(), state.current_cwd)
  end)
end)
