local state = require('opencode.state')
local store = require('opencode.state.store')
local Promise = require('opencode.promise')

local M = {}

function M.mock_api_client()
  state.jobs.set_api_client({
    create_session = function(_, params)
      return Promise.new():resolve({ id = params and params.title or 'new-session' })
    end,
    get_session = function(_, id)
      return Promise.new():resolve(id and { id = id, title = id, modified = os.time(), parentID = nil } or nil)
    end,
    create_message = function(_, sess_id, _params)
      return Promise.new():resolve({ id = 'm1', sessionID = sess_id })
    end,
    abort_session = function(_, _id)
      return Promise.new():resolve(true)
    end,
    get_current_project = function()
      return Promise.new():resolve({ id = 'test-project-id' })
    end,
    get_config = function()
      return Promise.new():resolve({ model = 'gpt-4' })
    end,
    list_permissions = function()
      return Promise.new():resolve({})
    end,
  })
end

function M.snapshot_state()
  return {
    state = vim.deepcopy(state),
    system = vim.system,
    executable = vim.fn.executable,
    schedule = vim.schedule,
  }
end

function M.restore_state(snapshot)
  for k, v in pairs(snapshot.state) do
    store.set(k, v)
  end

  vim.system = snapshot.system
  vim.fn.executable = snapshot.executable
  vim.schedule = snapshot.schedule
end

return M
