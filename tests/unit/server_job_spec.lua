local server_job = require('opencode.server_job')

local curl = require('opencode.curl')
local assert = require('luassert')

describe('server_job', function()
  local original_curl_request
  local opencode_server = require('opencode.opencode_server')
  local original_new

  before_each(function()
    original_curl_request = curl.request
    original_new = opencode_server.new
  end)

  after_each(function()
    curl.request = original_curl_request
    opencode_server.new = original_new

    local state = require('opencode.state')
    state.opencode_server = nil
  end)

  it('exposes expected public functions', function()
    assert.is_function(server_job.call_api)
    assert.is_function(server_job.stream_api)
    assert.is_function(server_job.ensure_server)
  end)

  it('call_api resolves with decoded json and toggles is_job_running', function()
    local state = require('opencode.state')
    curl.request = function(opts)
      -- simulate async callback
      vim.schedule(function()
        assert.equal(1, state.job_count)
        opts.callback({ status = 200, body = '{"hello":"world"}' })
      end)
    end

    local result = server_job.call_api('http://localhost:1234/test', 'GET'):wait()
    assert.same({ hello = 'world' }, result)
    assert.equal(0, state.job_count) -- reset
  end)

  it('call_api rejects on non 2xx', function()
    curl.request = function(opts)
      vim.schedule(function()
        opts.callback({ status = 500, body = '{"error":"boom"}' })
      end)
    end

    local ok, err = pcall(function()
      server_job.call_api('http://localhost:1234/test', 'GET'):wait()
    end)
    assert.is_false(ok)
    if type(err) == 'table' then
      assert.equals('boom', err.error)
    else
      assert.truthy(err:match('boom'))
    end
  end)

  it('stream_api forwards chunks', function()
    local collected = {}
    curl.request = function(opts)
      -- simulate streaming by calling stream multiple times
      vim.schedule(function()
        opts.stream(nil, 'part1')
        opts.stream(nil, 'part2')
      end)
      return { pid = 1 }
    end

    server_job.stream_api('http://localhost:1234/stream', 'GET', nil, function(chunk)
      table.insert(collected, chunk)
    end)

    vim.wait(50, function()
      return #collected == 2
    end)

    assert.same({ 'part1', 'part2' }, collected)
  end)

  it('ensure_server spawns a new opencode server only once', function()
    local spawn_count = 0
    local captured_cwd
    local fake = {
      url = 'http://127.0.0.1:4000',
      is_running = function()
        return spawn_count > 0
      end,
      spawn = function(self, opts)
        spawn_count = spawn_count + 1
        captured_cwd = opts.cwd
        vim.schedule(function()
          opts.on_ready({}, self.url)
        end)
      end,
      shutdown = function() end,
    }
    opencode_server.new = function()
      return fake
    end

    local first = server_job.ensure_server():wait()
    assert.same(fake, first._value or first) -- ensure_server returns resolved promise value
    local second = server_job.ensure_server():wait()
    assert.same(fake, second._value or second)
    assert.equal(1, spawn_count)
    assert.equals(vim.fn.getcwd(), captured_cwd)
  end)

end)
