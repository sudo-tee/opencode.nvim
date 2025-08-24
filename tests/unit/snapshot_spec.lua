local snapshot = require('opencode.snapshot')
local state = require('opencode.state')

-- Save originals to restore after tests
local orig_notify = vim.notify
local orig_system = vim.system
local orig_getcwd = vim.fn.getcwd

describe('snapshot.restore', function()
  local system_calls = {}

  before_each(function()
    -- Reset system calls tracking
    system_calls = {}

    -- Mock notify, system, getcwd
    vim.notify = function(msg, level)
      vim.g._last_notify = { msg = msg, level = level }
    end

    vim.system = function(cmd, opts)
      table.insert(system_calls, { cmd = cmd, opts = opts })
      vim.g._last_system = { cmd = cmd, opts = opts }
      -- Simulate success for both commands
      return {
        wait = function()
          return { code = 0, stdout = '', stderr = '' }
        end,
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
    system_calls = {}
  end)

  it('runs read-tree and checkout-index and notifies on success', function()
    snapshot.restore('abc123')

    -- Should have made 2 system calls
    assert.equal(2, #system_calls)

    -- First call: read-tree
    assert.same({ 'git', '-C', '/mock/gitdir', 'read-tree', 'abc123' }, system_calls[1].cmd)

    -- Second call: checkout-index
    assert.same({ 'git', '-C', '/mock/gitdir', 'checkout-index', '-a', '-f' }, system_calls[2].cmd)

    -- Notification
    assert.is_truthy(vim.g._last_notify)
    assert.is_truthy(vim.g._last_notify.msg:find('Restored snapshot'))
  end)

  it('notifies error if no active session', function()
    state.active_session = nil
    snapshot.restore('abc123')
    assert.is_truthy(vim.g._last_notify)
    -- Should match either "No snapshot path" or "Failed to read-tree" depending on implementation
    local msg = vim.g._last_notify.msg
    assert.is_truthy(msg:find('No snapshot path') or msg:find('Failed to read%-tree'))
  end)

  it('notifies error if read-tree fails', function()
    vim.system = function(cmd, opts)
      return {
        wait = function()
          return { code = 1, stdout = '', stderr = 'fail read-tree' }
        end,
      }
    end
    snapshot.restore('abc123')
    assert.is_truthy(vim.g._last_notify)
    assert.is_truthy(vim.g._last_notify.msg:find('Failed to read%-tree'))
  end)

  it('notifies error if checkout-index fails', function()
    local call_count = 0
    vim.system = function(cmd, opts)
      call_count = call_count + 1
      if call_count == 1 then
        return {
          wait = function()
            return { code = 0, stdout = '', stderr = '' }
          end,
        }
      else
        return {
          wait = function()
            return { code = 1, stdout = '', stderr = 'fail checkout' }
          end,
        }
      end
    end
    snapshot.restore('abc123')
    assert.is_truthy(vim.g._last_notify)
    assert.is_truthy(vim.g._last_notify.msg:find('Failed to checkout%-index'))
  end)
end)
