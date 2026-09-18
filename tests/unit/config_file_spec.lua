local config_file = require('opencode.config_file')
local Promise = require('opencode.promise')
local state = require('opencode.state')
local stub = require('luassert.stub')

describe('config_file.setup', function()
  local original_schedule
  local original_server

  local function set_operations(operations)
    state.jobs.set_server({
      operations = operations,
      is_ready = function()
        return true
      end,
      check_health = function()
        return Promise.new():resolve(true)
      end,
    })
  end

  before_each(function()
    original_schedule = vim.schedule
    vim.schedule = function(fn)
      fn()
    end
    original_server = state.opencode_server
    config_file.config_promise = nil
    config_file.project_promise = nil
    config_file.providers_promise = nil
  end)

  after_each(function()
    vim.schedule = original_schedule
    state.jobs.set_server(original_server)
  end)

  it('lazily loads config when accessed', function()
    Promise.spawn(function()
      local get_config_called, get_project_called = false, false
      local cfg = { agent = { ['a1'] = { mode = 'primary' } } }
      set_operations({
        get_config = function()
          get_config_called = true
          return Promise.new():resolve(cfg)
        end,
        get_current_project = function()
          get_project_called = true
          return Promise.new():resolve({ id = 'p1', name = 'P', path = '/tmp' })
        end,
      })

      -- Promises should not be set up during setup (lazy loading)
      assert.falsy(config_file.config_promise)
      assert.falsy(config_file.project_promise)

      -- Accessing config should trigger lazy loading
      local resolved_cfg = config_file.get_opencode_config():await()
      assert.same(cfg, resolved_cfg)
      assert.True(get_config_called)

      -- Project should be loaded when accessed
      local project = config_file.get_opencode_project():await()
      assert.True(get_project_called)
    end):wait()
  end)

  it('gets primary agents from the selected protocol', function()
    Promise.spawn(function()
      set_operations({
        list_primary_agents = function()
          return Promise.new():resolve({
            'orchestrator',
            'study',
          })
        end,
      })

      assert.same({ 'orchestrator', 'study' }, config_file.get_opencode_agents():await())
    end):wait()
  end)

  it('retries an empty primary-agent response while the server initializes', function()
    local original_defer_fn = vim.defer_fn
    local attempts = 0
    vim.defer_fn = function(callback)
      callback()
    end

    set_operations({
      list_primary_agents = function()
        attempts = attempts + 1
        return Promise.new():resolve(attempts < 3 and {} or { 'build' })
      end,
    })

    local agents = config_file.get_opencode_agents():wait()

    vim.defer_fn = original_defer_fn
    assert.same({ 'build' }, agents)
    assert.equals(3, attempts)
  end)

  it('gets subagents from the selected protocol', function()
    Promise.spawn(function()
      set_operations({
        list_subagents = function()
          return Promise.new():resolve({ 'explore', 'coder' })
        end,
      })
      assert.same({ 'explore', 'coder' }, config_file.get_subagents():await())
    end):wait()
  end)

  it('starts the server before fetching a resource', function()
    local server_job = require('opencode.server_job')
    local original_server = state.opencode_server
    local connection = {
      operations = {
        list_primary_agents = function()
          return Promise.new():resolve({ 'build' })
        end,
      },
    }
    local ensure_server = stub(server_job, 'ensure_server').returns(Promise.new():resolve(connection))
    state.jobs.clear_server()

    local agents = config_file.get_opencode_agents():wait()

    assert.same({ 'build' }, agents)
    assert.stub(ensure_server).was_called()

    ensure_server:revert()
    state.jobs.set_server(original_server)
  end)

  it('get_opencode_project returns project', function()
    Promise.spawn(function()
      local project = { id = 'p1', name = 'X' }
      set_operations({
        get_config = function()
          return Promise.new():resolve({ agent = {} })
        end,
        get_current_project = function()
          return Promise.new():resolve(project)
        end,
      })
      local proj = config_file.get_opencode_project():await()
      assert.same(project, proj)
    end):wait()
  end)
end)
