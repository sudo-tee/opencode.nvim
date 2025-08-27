-- tests/unit/config_spec.lua
-- Tests for the config module

local config = require('opencode.config')

describe('opencode.config', function()
  -- Save original config values
  local original_config

  -- Save the original config before all tests
  before_each(function()
    original_config = vim.deepcopy(config.values)
    -- Reset to default config
    config.values = vim.deepcopy(config.defaults)
  end)

  -- Restore original config after all tests
  after_each(function()
    config.values = original_config
  end)

  it('uses default values when no options are provided', function()
    config.setup(nil)
    assert.same(config.defaults, config.values)
  end)

  it('merges user options with defaults', function()
    local custom_callback = function()
      return 'custom'
    end
    config.setup({
      command_callback = custom_callback,
    })

    assert.equal(custom_callback, config.values.command_callback)
    assert.same(config.defaults.keymap, config.values.keymap)
  end)
end)
