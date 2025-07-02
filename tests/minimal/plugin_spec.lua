-- tests/minimal/plugin_spec.lua
-- Integration tests for the full plugin

local helpers = require("tests.helpers")

describe("opencode.nvim plugin", function()
  it("loads the plugin without errors", function()
    -- Simply test that the plugin can be required
    local opencode = require("opencode")
    assert.truthy(opencode, "Plugin should be loaded")
    assert.is_function(opencode.setup, "setup function should be available")

    -- We don't check for opencode_command anymore as it's been removed
    -- Instead test the job module
    local job = require("opencode.job")
    assert.truthy(job, "job module should be loaded")
    assert.is_function(job.build_args, "build_args function should be available")
    assert.is_function(job.execute, "execute function should be available")
  end)

  it("can be set up with custom config", function()
    local opencode = require("opencode")

    -- Setup with custom config matching new structure
    opencode.setup({
      keymap = {
        prompt = "<leader>test"
      }
    })

    -- Check that config was set correctly
    local config = require("opencode.config")
    assert.equal("<leader>test", config.get("keymap").prompt)
  end)
end)
