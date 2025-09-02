-- tests/minimal/plugin_spec.lua
-- Integration tests for the full plugin

local core = require('opencode.core')
local server_job = require('opencode.server_job')

describe('opencode.nvim plugin', function()
  local original_run_server_api
  local original_schedule

  before_each(function()
    original_schedule = vim.schedule
    vim.schedule = function(fn)
      fn()
    end
    -- Mock core.run_server_api to prevent server spawning
    original_run_server_api = core.run_server_api
    server_job.with_server = function(cb, opts)
      vim.schedule(function()
        cb({
          shutdown = function() end,
        }, 'http://localhost:1234')
      end)
    end
    core.run_server_api = function(_, _m, _b, opts)
      -- Mock successful response
      if opts.on_done then
        opts.on_done({ agents = {} })
      end
    end
  end)

  after_each(function()
    -- Restore original function
    if original_run_server_api then
      core.run_server_api = original_run_server_api
    end
    vim.schedule = original_schedule
  end)

  it('loads the plugin without errors', function()
    -- Simply test that the plugin can be required
    local opencode = require('opencode')
    assert.truthy(opencode, 'Plugin should be loaded')
    assert.is_function(opencode.setup, 'setup function should be available')

    local job = require('opencode.job')
    assert.truthy(job, 'job module should be loaded')
    assert.is_function(job.build_args, 'build_args function should be available')
    assert.is_function(job.execute, 'execute function should be available')
  end)

  it('can be set up with custom config', function()
    local opencode = require('opencode')

    -- Setup with custom config matching new structure
    opencode.setup({
      keymap = {
        prompt = '<leader>test',
      },
    })

    -- Check that config was set correctly
    local config = require('opencode.config')
    assert.equal('<leader>test', config.get('keymap').prompt)
  end)
end)
