-- tests/minimal/plugin_spec.lua
-- Integration tests for the full plugin (lightweight)

local Promise = require('opencode.promise')

describe('opencode.nvim plugin', function()
  local original_schedule
  local original_ensure_server
  local original_api_client_new
  local original_system
  local original_executable

  before_each(function()
    original_schedule = vim.schedule
    vim.schedule = function(fn) fn() end

    -- Mock vim.system for opencode version check
    original_system = vim.system
    vim.system = function(_cmd, _opts)
      return {
        wait = function()
          return { stdout = 'opencode 0.6.3' }
        end,
      }
    end

    -- Mock vim.fn.executable for opencode check
    original_executable = vim.fn.executable
    vim.fn.executable = function(_)
      return 1
    end

    -- Stub ensure_server so no real process is spawned
    local server_job = require('opencode.server_job')
    original_ensure_server = server_job.ensure_server
    server_job.ensure_server = function()
      return { url = 'http://localhost:9000', is_running = function() return true end }
    end

    -- Stub api_client constructor to return mock with needed methods
    local api_client_mod = require('opencode.api_client')
    original_api_client_new = api_client_mod.new
    api_client_mod.new = function(url)
      return {
        url = url,
        get_config = function()
          return Promise.new():resolve({ agent = {} })
        end,
        get_current_project = function()
          return Promise.new():resolve({ id = 'p1', name = 'TestProject', path = '/tmp' })
        end,
        create_session = function()
          return Promise.new():resolve({ id = 's1' })
        end,
        create_message = function(_, _id, _params)
          return Promise.new():resolve({ id = 'm1' })
        end,
        abort_session = function() return Promise.new():resolve(true) end,
      }
    end
  end)

  after_each(function()
    vim.schedule = original_schedule
    vim.system = original_system
    vim.fn.executable = original_executable
    if original_ensure_server then
      require('opencode.server_job').ensure_server = original_ensure_server
    end
    if original_api_client_new then
      require('opencode.api_client').new = original_api_client_new
    end
  end)

  it('loads the plugin without errors', function()
    local opencode = require('opencode')
    assert.truthy(opencode, 'Plugin should be loaded')
    assert.is_function(opencode.setup, 'setup function should be available')
  end)

  it('can be set up with custom config', function()
    local opencode = require('opencode')

    opencode.setup({
      keymap = { prompt = '<leader>test' },
    })

    local config = require('opencode.config')
    assert.equal('<leader>test', config.keymap.prompt)
  end)
end)
