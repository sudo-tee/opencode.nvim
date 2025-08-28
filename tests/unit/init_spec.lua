-- tests/unit/init_spec.lua
-- Tests for the init module (public API)

local opencode = require('opencode')

describe('opencode', function()
  it('has setup function in the public API', function()
    assert.is_function(opencode.setup)
  end)

  -- The old opencode_command function has been replaced, so we're just testing
  -- that the main module exists and can be required
  it('main module can be required without errors', function()
    assert.is_table(opencode)
  end)
end)
