local snapshot = require('opencode.snapshot')
local state = require('opencode.state')

-- Save originals to restore after tests
local orig_notify = vim.notify
local orig_system = vim.system
local orig_getcwd = vim.fn.getcwd

describe('snapshot.restore', function()
  before_each(function()
    -- Mock notify, system, getcwd
    vim.notify = function(msg, level)
      vim.g._last_notify = { msg = msg, level = level }
    end
    vim.system = function(cmd, opts)
      vim.g._last_system = { cmd = cmd, opts = opts }
      -- Simulate success for both commands
      return {
        wait = function()
          return { code = 0, stdout = '', stderr = '' }
        end
      }
    end
    vim.fn.getcwd = function()
      return '/mock/project/root'
    end
    state.active_session = { snapshot_path = '/mock/gitdir' }
    vim.g._last_notify = nil
    vim.g._last_system = nil
  end)

  after_each(function()
    vim.notify = orig_notify
    vim.system = orig_system
    vim.fn.getcwd = orig_getcwd
    state.active_session = nil
    vim.g._last_notify = nil
    vim.g._last_system = nil
  end)

  it('runs read-tree and checkout-index and notifies on success', function()
    snapshot.restore('abc123')
    -- First call: read-tree
    assert.same(
      { 'git', '--git-dir=/mock/gitdir', 'read-tree', 'abc123' },
      vim.g._last_system.cmd
    )
    assert.same('/mock/project/root', vim.g._last_system.opts.cwd)
    -- Second call: checkout-index
    -- The second call will overwrite _last_system, so we only check the last one
    snapshot.restore('abc123')
    assert.same(
      { 'git', '--git-dir=/mock/gitdir', 'checkout-index', '-a', '-f' },
      vim.g._last_system.cmd
    )
    assert.same('/mock/project/root', vim.g._last_system.opts.cwd)
    -- Notification
    assert.is_truthy(vim.g._last_notify)
    assert.is_true(vim.g._last_notify.msg:find('Restored snapshot'))
  end)

  it('notifies error if no active session', function()
    state.active_session = nil
    snapshot.restore('abc123')
    assert.is_truthy(vim.g._last_notify)
    assert.is_true(vim.g._last_notify.msg:find('No snapshot path'))
  end)

  it('notifies error if read-tree fails', function()
    vim.system = function(cmd, opts)
      return {
        wait = function()
          return { code = 1, stdout = '', stderr = 'fail read-tree' }
        end
      }
    end
    snapshot.restore('abc123')
    assert.is_truthy(vim.g._last_notify)
    assert.is_true(vim.g._last_notify.msg:find('Failed to read-tree'))
  end)

  it('notifies error if checkout-index fails', function()
    local call_count = 0
    vim.system = function(cmd, opts)
      call_count = call_count + 1
      if call_count == 1 then
        return {
          wait = function()
            return { code = 0, stdout = '', stderr = '' }
          end
        }
      else
        return {
          wait = function()
            return { code = 1, stdout = '', stderr = 'fail checkout' }
          end
        }
      end
    end
    snapshot.restore('abc123')
    assert.is_truthy(vim.g._last_notify)
    assert.is_true(vim.g._last_notify.msg:find('Failed to checkout-index'))
  end)
end)
