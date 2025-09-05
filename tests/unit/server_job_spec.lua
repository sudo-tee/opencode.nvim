-- Mock vim.system before requiring any modules to prevent real process spawning

-- Mock opencode_server before requiring server_job to prevent any real server spawning
local opencode_server = require('opencode.opencode_server')
local original_opencode_server_new = opencode_server.new
opencode_server.new = function()
  return {
    spawn = function() end,
    shutdown = function() end,
  }
end

local server_job = require('opencode.server_job')

describe('server_job', function()
  local original_curl_request

  before_each(function()
    -- Mock curl.request
    local curl = require('plenary.curl')
    original_curl_request = curl.request
  end)

  after_each(function()
    if original_curl_request then
      local curl = require('plenary.curl')
      curl.request = original_curl_request
    end
    -- Reset opencode_server.new to default mock
    opencode_server.new = function()
      return {
        spawn = function() end,
        shutdown = function() end,
      }
    end
  end)

  it('should expose call_api and run', function()
    assert.is_function(server_job.call_api)
    assert.is_function(server_job.run)
  end)

  it('should call on_ready and make API call, then shutdown', function()
    local curl = require('plenary.curl')
    local shutdown_called = false
    local spawn_called = false
    local fake_server = {
      spawn = function(self, opts)
        spawn_called = true
        -- Simulate server ready
        opts.on_ready(self, 'http://127.0.0.1:41961')
      end,
      shutdown = function(self)
        shutdown_called = true
      end,
    }
    opencode_server.new = function()
      return fake_server
    end
    curl.request = function(opts)
      -- Simulate successful API response
      vim.schedule(function()
        opts.callback({ status = 200, body = '{"ok":true}' })
      end)
    end
    local done_called, done_result
    server_job.run('/api/test', 'GET', nil, {
      cwd = '.',
      on_done = function(result)
        done_called = true
        done_result = result
      end,
      on_error = function(err)
        assert(false, 'Should not error: ' .. tostring(err))
      end,
      on_exit = function()
        -- not used in this test
      end,
    })
    vim.wait(100, function()
      return done_called
    end, 10)
    assert.is_true(spawn_called)
    assert.is_true(shutdown_called)
    assert.is_true(done_called)
    assert.same({ ok = true }, done_result)
  end)

  it('should call API and and return a promise', function()
    local curl = require('plenary.curl')
    local cb_result
    curl.request = function(opts)
      vim.schedule(function()
        opts.callback({ status = 200, body = '{"ok":true}' })
      end)
    end
    server_job
      .call_api('http://localhost:8080/api/test', 'GET', nil)
      :and_then(function(result)
        cb_result = result
      end)
      :wait()
    assert.same({ ok = true }, cb_result)
  end)
end)
