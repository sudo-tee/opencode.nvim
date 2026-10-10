local assert = require('luassert')
local stub = require('luassert.stub')
local Promise = require('opencode.promise')
local state = require('opencode.state')
local config = require('opencode.config')
local runtime = require('opencode.services.session_runtime')
local support = require('tests.unit.services_spec_support')

describe('session lock policy', function()
  local base, project, other, saved, previous_policy, ensure, open, notify
  local seen

  before_each(function()
    base = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.tempname(), ':p'))
    project, other = base .. '/project', base .. '/other'
    vim.fn.mkdir(project, 'p')
    vim.fn.mkdir(other, 'p')
    saved = vim.deepcopy(state.store.state())
    previous_policy = config.lock_session_to_directory
    seen = {}
    state.session_tabs.reset()
    state.ui.set_windows(nil)
    state.session.set_locked(nil)
    state.context.set_current_cwd(project)
    state.session.set_active({ id = 'work', location = { directory = project } })
    state.session_tabs.ensure_current()
    local connection = support.mock_connection()
    connection.operations.list_sessions_project = function(_, location)
      return Promise.new():resolve({ { id = 'other', location = location, time = { updated = 2 } } })
    end
    ensure = stub(require('opencode.server_job'), 'ensure_server').returns(Promise.new():resolve(connection))
    open = stub(runtime, 'open').invokes(function()
      runtime.check_cwd()
      return Promise.new():resolve('ok')
    end)
    notify = stub(vim, 'notify')
  end)

  after_each(function()
    ensure:revert()
    open:revert()
    notify:revert()
    config.lock_session_to_directory = previous_policy
    state.session_tabs.reset()
    vim.fn.delete(base, 'rf')
    for key in pairs(state.store.state()) do
      state.store.set_raw(key, nil)
    end
    for key, value in pairs(saved) do
      state.store.set_raw(key, value)
    end
  end)

  it('passes from, to, and session to the function', function()
    config.lock_session_to_directory = function(change)
      table.insert(seen, change)
      return true
    end
    assert.is_true(runtime.is_session_locked(other))
    assert.equal(project, seen[1].from)
    assert.equal(other, seen[1].to)
    assert.equal('work', seen[1].session.id)
  end)

  it('keeps the session when the function returns true', function()
    config.lock_session_to_directory = function()
      return true
    end
    runtime.handle_directory_change(other):wait()
    assert.equal('work', state.active_session.id)
    assert.equal(other, state.current_cwd)
  end)

  it('loads the target when the function returns false', function()
    config.lock_session_to_directory = function()
      return false
    end
    runtime.handle_directory_change(other):wait()
    assert.equal('other', state.active_session.id)
    assert.equal(other, state.current_cwd)
  end)

  it('follows the cwd when the function errors and reports it', function()
    config.lock_session_to_directory = function()
      error('boom')
    end
    assert.is_false(runtime.is_session_locked(other))
    assert.stub(notify).was_called()
  end)

  it('uses the bound directory as from', function()
    runtime.open_session({ directory = project, session_id = 'bound' }):wait()
    config.lock_session_to_directory = function(change)
      table.insert(seen, change)
      return false
    end
    runtime.is_session_locked(other)
    assert.equal(project, seen[1].from)
  end)

  it('applies the manual lock override before the function', function()
    config.lock_session_to_directory = function()
      return false
    end
    assert.is_true(runtime.toggle_session_lock())
    assert.is_true(runtime.is_session_locked(other))
    assert.is_false(runtime.set_session_lock(false))
    assert.is_false(runtime.is_session_locked(other))
  end)

  it('returns false without an active session', function()
    config.lock_session_to_directory = function()
      return true
    end
    state.session.clear_active()
    assert.is_false(runtime.is_session_locked(other))
  end)

  it('keeps a bound tab in its directory while the policy locks it', function()
    runtime.open_session({ directory = project, session_id = 'bound' }):wait()
    config.lock_session_to_directory = function()
      return true
    end
    local getcwd = stub(vim.fn, 'getcwd').returns(other)
    local ok, err = pcall(function()
      runtime.check_cwd()
      assert.equal(project, state.current_cwd)
      assert.equal('bound', state.active_session.id)
    end)
    getcwd:revert()
    assert.is_true(ok, tostring(err))
  end)

  it('supports a per-repository policy written against git', function()
    local repo, worktree = base .. '/repo', base .. '/repo-linked'
    vim.fn.mkdir(repo, 'p')
    local function git(directory, ...)
      local argv = vim.list_extend({ 'git', '-C', directory }, { ... })
      local result = vim.system(argv, { text = true }):wait()
      assert.equal(0, result.code, result.stderr)
    end
    git(repo, 'init', '--quiet')
    git(
      repo,
      '-c',
      'user.name=Test',
      '-c',
      'user.email=test@example.com',
      'commit',
      '--quiet',
      '--allow-empty',
      '-m',
      'Initial'
    )
    git(repo, 'worktree', 'add', '--quiet', '--detach', worktree)

    config.lock_session_to_directory = function(change)
      local function common_dir(dir)
        local r = vim
          .system({ 'git', '-C', dir, 'rev-parse', '--path-format=absolute', '--git-common-dir' }, { text = true })
          :wait()
        return r.code == 0 and vim.trim(r.stdout) or nil
      end
      local source = common_dir(change.from)
      return source ~= nil and source == common_dir(change.to)
    end

    state.session.set_active({ id = 'work', location = { directory = repo } })
    assert.is_true(runtime.is_session_locked(worktree))
    assert.is_false(runtime.is_session_locked(other))
  end)
end)
