local state = require('opencode.state')
local store = require('opencode.state.store')
local Promise = require('opencode.promise')
local M = {}

function M.mock_connection()
  local connection = { protocol = 'v1', operations = {}, observations = {}, session_facts = {} }
  connection.url = 'http://127.0.0.1:4000'
  function connection:is_ready()
    return true
  end
  function connection:can_release_process()
    return false
  end
  function connection:check_health()
    return Promise.new():resolve(true)
  end
  connection.operations.create_session = function(_, _, input)
    return Promise.new():resolve({
      id = input and input.title or 'new-session',
      title = input and input.title or 'new-session',
      time = { updated = 2 },
    })
  end
  connection.operations.list_sessions_project = function()
    return Promise.new():resolve({ { id = 'test-session', title = 'test-session', time = { updated = 2 } } })
  end
  connection.operations.list_sessions_global = connection.operations.list_sessions_project
  connection.operations.get_session = function(_, id)
    return Promise.new():resolve({ id = id, title = id, time = { updated = 2 } })
  end
  connection.operations.get_config = function()
    return Promise.new():resolve({ model = 'gpt-4' })
  end
  connection.operations.list_primary_agents = function()
    return Promise.new():resolve({ 'build' })
  end
  function connection:observe(ref)
    local existing = self.observations[ref.id]
    if existing then
      return existing
    end
    local fact =
      vim.tbl_deep_extend('force', { id = ref.id, location = ref.location }, self.session_facts[ref.id] or {})
    local observation = {
      _state = {
        session = fact,
        entries_by_id = {},
        entry_order = {},
        sync = { session = { state = 'current' } },
      },
      submit = function(_, _input)
        return Promise.new():resolve({ kind = 'reply', input_id = 'msg-user', message = { id = 'msg-reply' } })
      end,
      interrupt = function()
        return Promise.new():resolve(true)
      end,
      watch = function()
        return function() end
      end,
    }
    function observation:read()
      return self._state
    end
    self.observations[ref.id] = observation
    return observation
  end
  state.jobs.set_server(connection)
  return connection
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
