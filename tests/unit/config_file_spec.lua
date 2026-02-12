local config_file = require('opencode.config_file')
local Promise = require('opencode.promise')
local state = require('opencode.state')

describe('config_file.setup', function()
  local original_schedule
  local original_api_client

  before_each(function()
    original_schedule = vim.schedule
    vim.schedule = function(fn)
      fn()
    end
    original_api_client = state.api_client
    config_file.config_promise = nil
    config_file.project_promise = nil
  end)

  after_each(function()
    vim.schedule = original_schedule
    state.api_client = original_api_client
  end)

  it('lazily loads config when accessed', function()
    Promise.spawn(function()
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

  it('get_opencode_agents returns primary + defaults', function()
    Promise.spawn(function()
      state.api_client = {
        get_config = function()
          return Promise.new():resolve({ agent = { ['custom'] = { mode = 'primary' } } })
        end,
        get_current_project = function()
          return Promise.new():resolve({ id = 'p1' })
        end,
      }
      local agents = config_file.get_opencode_agents():await()
      assert.True(vim.tbl_contains(agents, 'custom'))
      assert.True(vim.tbl_contains(agents, 'build'))
      assert.True(vim.tbl_contains(agents, 'plan'))
    end):wait()
  end)

  it('get_opencode_agents respects disabled defaults', function()
    Promise.spawn(function()
      state.api_client = {
        get_config = function()
          return Promise.new():resolve({ agent = { ['custom'] = { mode = 'primary' }, ['build'] = { disable = true }, ['plan'] = { disable = false } } })
        end,
        get_current_project = function()
          return Promise.new():resolve({ id = 'p1' })
        end,
      }
      local agents = config_file.get_opencode_agents():await()
      assert.True(vim.tbl_contains(agents, 'custom'))
      assert.False(vim.tbl_contains(agents, 'build'))
      assert.True(vim.tbl_contains(agents, 'plan'))
    end):wait()
  end)

  it('get_opencode_agents filters out hidden agents', function()
    Promise.spawn(function()
      state.api_client = {
        get_config = function()
          return Promise.new():resolve({
            agent = {
              ['custom'] = { mode = 'primary' },
              ['compaction'] = { mode = 'primary', hidden = true },
              ['title'] = { mode = 'primary', hidden = true },
            },
          })
        end,
        get_current_project = function()
          return Promise.new():resolve({ id = 'p1' })
        end,
      }
      local agents = config_file.get_opencode_agents():await()
      assert.True(vim.tbl_contains(agents, 'custom'))
      assert.False(vim.tbl_contains(agents, 'compaction'))
      assert.False(vim.tbl_contains(agents, 'title'))
    end):wait()
  end)

  it('get_subagents filters out hidden agents', function()
    Promise.spawn(function()
      state.api_client = {
        get_config = function()
          return Promise.new():resolve({
            agent = {
              ['explore'] = { mode = 'all' },
              ['compaction'] = { mode = 'all', hidden = true },
              ['summary'] = { hidden = true },
            },
          })
        end,
        get_current_project = function()
          return Promise.new():resolve({ id = 'p1' })
        end,
      }
      local agents = config_file.get_subagents():await()
      assert.True(vim.tbl_contains(agents, 'general'))
      assert.True(vim.tbl_contains(agents, 'explore'))
      assert.False(vim.tbl_contains(agents, 'compaction'))
      assert.False(vim.tbl_contains(agents, 'summary'))
    end):wait()
  end)

  it('get_subagents does not duplicate built-in agents when configured', function()
    Promise.spawn(function()
      state.api_client = {
        get_config = function()
          return Promise.new():resolve({
            agent = {
              ['general'] = { mode = 'subagent', model = 'custom/model' },
              ['explore'] = { mode = 'all', temperature = 0.5 },
              ['custom'] = { mode = 'subagent' },
            },
          })
        end,
        get_current_project = function()
          return Promise.new():resolve({ id = 'p1' })
        end,
      }
      local agents = config_file.get_subagents():await()

      -- Count occurrences of each agent
      local general_count = 0
      local explore_count = 0
      for _, agent in ipairs(agents) do
        if agent == 'general' then
          general_count = general_count + 1
        elseif agent == 'explore' then
          explore_count = explore_count + 1
        end
      end

      -- Each should appear exactly once
      assert.equal(1, general_count, 'general should appear exactly once')
      assert.equal(1, explore_count, 'explore should appear exactly once')
      assert.True(vim.tbl_contains(agents, 'custom'))
    end):wait()
  end)

  it('get_subagents respects disabled built-in agents', function()
    Promise.spawn(function()
      state.api_client = {
        get_config = function()
          return Promise.new():resolve({
            agent = {
              ['general'] = { disable = true },
              ['explore'] = { hidden = true },
            },
          })
        end,
        get_current_project = function()
          return Promise.new():resolve({ id = 'p1' })
        end,
      }
      local agents = config_file.get_subagents():await()
      assert.False(vim.tbl_contains(agents, 'general'))
      assert.False(vim.tbl_contains(agents, 'explore'))
    end):wait()
  end)

  it('get_opencode_project returns project', function()
    Promise.spawn(function()
      local project = { id = 'p1', name = 'X' }
      state.api_client = {
        get_config = function()
          return Promise.new():resolve({ agent = {} })
        end,
        get_current_project = function()
          return Promise.new():resolve(project)
        end,
      }
      local proj = config_file.get_opencode_project():await()
      assert.same(project, proj)
    end):wait()
  end)
end)
