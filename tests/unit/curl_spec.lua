local curl = require('opencode.curl')

describe('curl stream handle lifecycle', function()
  local original_system

  before_each(function()
    original_system = vim.system
  end)

  after_each(function()
    vim.system = original_system
  end)

  it('marks stream handle as stopped after process exit', function()
    local on_complete

    vim.system = function(_, _, cb)
      on_complete = cb
      return {
        pid = 123,
        kill = function() end,
      }
    end

    local handle = curl.request({
      url = 'http://127.0.0.1:1/event',
      stream = function() end,
    })

    assert.is_true(handle.is_running())
    on_complete({ code = 0, signal = 0 })
    assert.is_false(handle.is_running())
  end)

  it('marks stream handle as stopped on shutdown', function()
    local killed = false

    vim.system = function(_, _, _)
      return {
        pid = 123,
        kill = function()
          killed = true
        end,
      }
    end

    local handle = curl.request({
      url = 'http://127.0.0.1:1/event',
      stream = function() end,
    })

    handle.shutdown()

    assert.is_true(killed)
    assert.is_false(handle.is_running())
  end)
end)
