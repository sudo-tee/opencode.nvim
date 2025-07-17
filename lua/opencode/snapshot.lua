local M = {}
local job = require('opencode.job')
local state = require('opencode.state')

function M.create()
  if not state.active_session then
    vim.notify('No active session', vim.log.levels.ERROR)
    return
  end

  job.execute('opencode snapshot create', {
    on_output = function(output)
      if output then
        vim.notify('Created snapshot: ' .. output, vim.log.levels.INFO)
      end
    end,
    on_error = function(err)
      vim.notify('Failed to create snapshot: ' .. err, vim.log.levels.ERROR)
    end,
  })
end

function M.restore(snapshot_id)
  if not state.active_session then
    vim.notify('No active session', vim.log.levels.ERROR)
    return
  end

  job.execute('opencode snapshot restore ' .. snapshot_id, {
    on_output = function()
      vim.notify('Restored snapshot: ' .. snapshot_id, vim.log.levels.INFO)
      vim.cmd('checktime')
    end,
    on_error = function(err)
      vim.notify('Failed to restore snapshot: ' .. err, vim.log.levels.ERROR)
    end,
  })
end

function M.diff(snapshot_id)
  if not state.active_session then
    vim.notify('No active session', vim.log.levels.ERROR)
    return
  end
  local cmd = {
    'git',
    '-C',
    state.active_session.snapshot_path,
    'diff',
    snapshot_id,
  }

  local out = vim.system(cmd):wait()
end

return M

