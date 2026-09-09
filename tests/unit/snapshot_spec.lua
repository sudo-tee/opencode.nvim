local snapshot = require('opencode.snapshot')
local state = require('opencode.state')
local Promise = require('opencode.promise')
local config_file = require('opencode.config_file')

describe('asynchronous snapshot operations', function()
  local original_system, original_notify, original_getcwd, original_path, original_session, original_delete
  local calls, notify, cwd
  before_each(function()
    original_system, original_notify = vim.system, vim.notify
    original_getcwd, original_path = vim.fn.getcwd, config_file.get_workspace_snapshot_path
    original_session, original_delete = state.active_session, vim.fn.delete
    cwd, calls = '/mock/project/root', {}
    vim.fn.getcwd = function()
      return cwd
    end
    vim.notify = function(message)
      notify = message
    end
    config_file.get_workspace_snapshot_path = function()
      return Promise.new():resolve('/mock/gitdir')
    end
    state.session.set_active({ id = 'origin' })
    vim.system = function(cmd, opts, on_exit)
      calls[#calls + 1] = { cmd = cmd, opts = opts }
      on_exit({ code = 0, stdout = '', stderr = '' })
      return {
        wait = function()
          error('must not block on a system process')
        end,
      }
    end
  end)
  after_each(function()
    vim.system, vim.notify = original_system, original_notify
    vim.fn.getcwd, config_file.get_workspace_snapshot_path = original_getcwd, original_path
    vim.fn.delete = original_delete
    state.session.set_active(original_session)
  end)
  it('runs read-tree and checkout-index in order', function()
    assert.is_true(snapshot.restore('abc123'):wait())
    assert.equals(2, #calls)
    assert.same({ 'git', '--git-dir', '/mock/gitdir', '--work-tree', cwd, 'read-tree', 'abc123' }, calls[1].cmd)
    assert.same({ 'git', '--git-dir', '/mock/gitdir', '--work-tree', cwd, 'checkout-index', '-a', '-f' }, calls[2].cmd)
    assert.matches('Restored snapshot', notify)
  end)
  it('rejects without an active session', function()
    state.session.clear_active()
    local result = snapshot.restore('abc123')
    assert.is_true(result:is_rejected())
    assert.equals(0, #calls)
  end)
  it('stops after read-tree failure', function()
    vim.system = function(_, _, cb)
      cb({ code = 1, stderr = 'read-tree failed' })
    end
    assert.is_nil(snapshot.restore('abc123'):wait())
    assert.matches('Failed to read%-tree', notify)
  end)
  it('reports checkout-index failure', function()
    local count = 0
    vim.system = function(_, _, cb)
      count = count + 1
      cb({ code = count == 1 and 0 or 1, stdout = '', stderr = 'checkout failed' })
    end
    assert.is_nil(snapshot.restore('abc123'):wait())
    assert.matches('Failed to checkout%-index', notify)
  end)
  it('yields and keeps the originating directory across startup and Git waits', function()
    local path = Promise.new()
    config_file.get_workspace_snapshot_path = function(directory)
      assert.equals('/mock/project/root', directory)
      return path
    end
    local callbacks = {}
    vim.system = function(cmd, opts, cb)
      calls[#calls + 1] = { cmd = cmd, opts = opts }
      callbacks[#callbacks + 1] = cb
      return {}
    end
    local result = snapshot.restore('abc123')
    assert.is_false(result:is_resolved())
    cwd = '/another/project'
    state.session.set_active({ id = 'another' })
    path:resolve('/mock/gitdir')
    assert.is_true(vim.wait(200, function()
      return #callbacks == 1
    end))
    callbacks[1]({ code = 0, stdout = '' })
    assert.is_true(vim.wait(200, function()
      return #callbacks == 2
    end))
    callbacks[2]({ code = 0, stdout = '' })
    assert.is_true(result:wait())
    for _, call in ipairs(calls) do
      assert.equals('/mock/project/root', call.opts.cwd)
      assert.equals('/mock/project/root', call.cmd[5])
    end
  end)
  it('serializes operations sharing a snapshot index', function()
    local callbacks = {}
    vim.system = function(cmd, _, cb)
      calls[#calls + 1] = cmd
      callbacks[#callbacks + 1] = cb
      return {}
    end
    local first, second = snapshot.restore('first'), snapshot.restore('second')
    assert.equals(1, #calls)
    callbacks[1]({ code = 0, stdout = '' })
    assert.is_true(vim.wait(200, function()
      return #calls == 2
    end))
    callbacks[2]({ code = 0, stdout = '' })
    assert.is_true(vim.wait(200, function()
      return #calls == 3
    end))
    assert.equals('second', calls[3][7])
    callbacks[3]({ code = 0, stdout = '' })
    assert.is_true(vim.wait(200, function()
      return #calls == 4
    end))
    callbacks[4]({ code = 0, stdout = '' })
    assert.is_true(first:wait())
    assert.is_true(second:wait())
  end)
  it('never deletes a file when checkout fails for a present snapshot path', function()
    local deleted = false
    vim.fn.delete = function()
      deleted = true
    end
    vim.system = function(cmd, _, cb)
      local command = cmd[6]
      cb({
        code = command == 'checkout' and 1 or 0,
        stdout = command == 'write-tree' and 'backup\n' or command == 'ls-tree' and 'file.lua\n' or '',
        stderr = 'index locked',
      })
    end
    local result = snapshot.revert_file('abc123', cwd .. '/file.lua')
    local ok = pcall(function()
      result:wait()
    end)
    assert.is_false(ok)
    assert.is_false(deleted)
  end)
  it('accepts file paths through symlink aliases', function()
    local real = vim.fn.tempname()
    local alias = real .. '-alias'
    vim.fn.mkdir(real, 'p')
    assert.is_true(vim.uv.fs_symlink(real, alias))
    vim.fn.writefile({ 'content' }, real .. '/file.lua')
    cwd = real

    local result = snapshot.diff_file('abc123', alias .. '/file.lua'):wait()

    assert.equals(alias .. '/file.lua', result.left)
    assert.equals('abc123:file.lua', calls[1].cmd[#calls[1].cmd])
    vim.fn.delete(alias, 'rf')
    vim.fn.delete(real, 'rf')
  end)
end)

describe('snapshot Git integration', function()
  local root, cwd, original_path, original_session, original_cache, session
  before_each(function()
    root, cwd = vim.fn.tempname(), vim.fn.getcwd()
    vim.fn.mkdir(root .. '/work', 'p')
    vim.fn.mkdir(root .. '/cache', 'p')
    root = vim.fn.resolve(root)
    assert.equals(0, vim.system({ 'git', 'init', '--bare', root .. '/snapshot' }):wait().code)
    vim.cmd.cd(vim.fn.fnameescape(root .. '/work'))
    original_path = config_file.get_workspace_snapshot_path
    original_session = state.active_session
    session = require('opencode.session')
    original_cache = session.get_cache_path
    session.get_cache_path = function()
      return root .. '/cache/'
    end
    config_file.get_workspace_snapshot_path = function()
      return Promise.new():resolve(root .. '/snapshot')
    end
    state.session.set_active({ id = 'integration' })
  end)
  after_each(function()
    vim.cmd.cd(vim.fn.fnameescape(cwd))
    config_file.get_workspace_snapshot_path = original_path
    session.get_cache_path = original_cache
    state.session.set_active(original_session)
    vim.fn.delete(root, 'rf')
  end)
  it('preserves diff bytes and restores an edited file with a recovery snapshot', function()
    local file = root .. '/work/file with spaces.lua'
    vim.fn.writefile({ '  original', '' }, file)
    local hash = snapshot.create():wait()
    assert.is_string(hash)
    vim.fn.writefile({ 'edited' }, file)
    local diff = snapshot.diff_file(hash, file):wait()
    assert.same({ '  original', '' }, vim.fn.readfile(diff.right))
    vim.fn.delete(diff.right)
    local recovery = snapshot.revert_file(hash, file):wait()
    assert.same({ '  original', '' }, vim.fn.readfile(file))
    assert.is_string(recovery.id)
    assert.is_true(snapshot.restore_file(recovery.id, file):wait())
    assert.same({ 'edited' }, vim.fn.readfile(file))
  end)
  it('deletes only files absent from the target and captures them for recovery', function()
    vim.fn.writefile({ 'original' }, root .. '/work/tracked')
    local hash = snapshot.create():wait()
    local added = root .. '/work/new file'
    vim.fn.writefile({ 'new' }, added)
    local recovery = snapshot.revert(hash):wait()
    assert.same({ added }, recovery.deleted_files)
    assert.equals(0, vim.fn.filereadable(added))
    assert.is_true(snapshot.restore(recovery.id):wait())
    assert.same({ 'new' }, vim.fn.readfile(added))
  end)
end)
