local config_file = require('opencode.config_file')
local Promise = require('opencode.promise')
local state = require('opencode.state')

describe('config_file.setup', function()
  local original_schedule
  local original_api_client

  before_each(function()
    original_schedule = vim.schedule
    vim.schedule = function(fn) fn() end
    original_api_client = state.api_client
    config_file.config_promise = nil
    config_file.project_promise = nil
  end)

  after_each(function()
    vim.schedule = original_schedule
    state.api_client = original_api_client
  end)

  it('lazily loads config when accessed', function()
    local get_config_called, get_project_called = false, false
    local cfg = { agent = { ['a1'] = { mode = 'primary' } } }
    state.api_client = {
      get_config = function()
        get_config_called = true
        return Promise.new():resolve(cfg)
      end,
      get_current_project = function()
        get_project_called = true
        return Promise.new():resolve({ id = 'p1', name = 'P', path = '/tmp' })
      end,
    }

    config_file.setup()
    -- Promises should not be set up during setup (lazy loading)
    assert.falsy(config_file.config_promise)
    assert.falsy(config_file.project_promise)
    
    -- Accessing config should trigger lazy loading
    local resolved_cfg = config_file.get_opencode_config()
    assert.same(cfg, resolved_cfg)
    assert.True(get_config_called)
    
    -- Project should be loaded when accessed
    local project = config_file.get_opencode_project()
    assert.True(get_project_called)
  end)

  it('get_opencode_agents returns primary + defaults', function()
    state.api_client = {
      get_config = function()
        return Promise.new():resolve({ agent = { ['custom'] = { mode = 'primary' } } })
      end,
      get_current_project = function()
        return Promise.new():resolve({ id = 'p1' })
      end,
    }
    -- No need to call setup() since config is loaded lazily
    local agents = config_file.get_opencode_agents()
    assert.True(vim.tbl_contains(agents, 'custom'))
    assert.True(vim.tbl_contains(agents, 'build'))
    assert.True(vim.tbl_contains(agents, 'plan'))
  end)

  it('get_opencode_project returns project', function()
    local project = { id = 'p1', name = 'X' }
    state.api_client = {
      get_config = function()
        return Promise.new():resolve({ agent = {} })
      end,
      get_current_project = function()
        return Promise.new():resolve(project)
      end,
    }
    -- No need to call setup() since project is loaded lazily
    local proj = config_file.get_opencode_project()
    assert.same(project, proj)
  end)
end)
