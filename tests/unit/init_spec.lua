-- tests/unit/init_spec.lua
-- Tests for the init module (public API)

local opencode = require('opencode')

describe('opencode', function()
  it('has setup function in the public API', function()
    assert.is_function(opencode.setup)
  end)

  it('exposes completion source registration in the public API', function()
    assert.is_function(opencode.register_completion_source)
    assert.is_function(opencode.unregister_completion_source)
  end)

  it('registers and unregisters completion sources through the public API', function()
    local source = {
      name = 'public_api_source',
      complete = function()
        return {}
      end,
    }

    opencode.register_completion_source(source)
    assert.are.equal(source, require('opencode.ui.completion').get_source_by_name(source.name))
    assert.is_true(opencode.unregister_completion_source(source.name))
  end)

  -- The old opencode_command function has been replaced, so we're just testing
  -- that the main module exists and can be required
  it('main module can be required without errors', function()
    assert.is_table(opencode)
  end)
end)
