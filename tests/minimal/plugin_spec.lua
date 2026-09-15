-- tests/minimal/plugin_spec.lua
-- Integration tests for the full plugin (lightweight)

describe('opencode.nvim plugin', function()
  local original_schedule
  local original_ensure_server
  local original_system
  local original_executable

  before_each(function()
    original_schedule = vim.schedule
    vim.schedule = function(fn)
      fn()
    end

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
      return {
        url = 'http://localhost:9000',
        is_running = function()
          return true
        end,
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
  end)

  it('loads the plugin without errors', function()
    local opencode = require('opencode')
    assert.truthy(opencode, 'Plugin should be loaded')
    assert.is_function(opencode.setup, 'setup function should be available')
  end)

  it('can be set up with custom config', function()
    local opencode = require('opencode')

    opencode.setup({
      default_global_keymaps = false,
      keymap = {
        editor = {
          ['<leader>test'] = { 'toggle' },
        },
      },
    })

    local config = require('opencode.config')
    assert.same({ 'toggle' }, config.keymap.editor['<leader>test'])
  end)
end)
