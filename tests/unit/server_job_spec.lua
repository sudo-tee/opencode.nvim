local server_job = require('opencode.server_job')

local curl = require('opencode.curl')
local config = require('opencode.config')
local assert = require('luassert')

describe('server_job', function()
  local original_curl_request
  local original_call_api
  local original_system
  local opencode_server = require('opencode.opencode_server')
  local original_new
  local original_runtime

  before_each(function()
    original_curl_request = curl.request
    original_call_api = server_job.call_api
    original_system = vim.system
    original_new = opencode_server.new
    original_runtime = vim.deepcopy(config.runtime)
  end)

  after_each(function()
    curl.request = original_curl_request
    server_job.call_api = original_call_api
    vim.system = original_system
    opencode_server.new = original_new
    config.runtime = original_runtime

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

  it('ensure_server connects to remote url without spawning', function()
    config.runtime.connection = 'remote'
    config.runtime.remote_url = '127.0.0.1:4096/'

    local spawn_called = false
    local connect_called = false

    local fake = {
      url = nil,
      is_running = function(self)
        return self.url ~= nil
      end,
      spawn = function()
        spawn_called = true
      end,
      connect = function(self, url)
        connect_called = true
        self.url = url
      end,
      shutdown = function() end,
    }

    opencode_server.new = function()
      return fake
    end

    server_job.call_api = function(url, method)
      assert.equals('http://127.0.0.1:4096/config', url)
      assert.equals('GET', method)
      return require('opencode.promise').new():resolve({ ['$schema'] = 'ok' })
    end

    local result = server_job.ensure_server():wait()

    assert.same(fake, result)
    assert.is_true(connect_called)
    assert.is_false(spawn_called)

  end)

  it('ensure_server rejects in remote mode when remote_url is missing', function()
    config.runtime.connection = 'remote'
    config.runtime.remote_url = nil

    local ok = pcall(function()
      server_job.ensure_server():wait()
    end)

    assert.is_false(ok)
  end)

  it('ensure_server rejects for invalid runtime.connection', function()
    config.runtime.connection = 'invalid'

    local ok = pcall(function()
      server_job.ensure_server():wait()
    end)

    assert.is_false(ok)
  end)

  it('ensure_server rejects in remote mode when remote_url is malformed', function()
    config.runtime.connection = 'remote'
    config.runtime.remote_url = '   '

    local ok = pcall(function()
      server_job.ensure_server():wait()
    end)

    assert.is_false(ok)
  end)

  it('ensure_server runs pre_start_command before spawn mode startup', function()
    config.runtime.connection = 'spawn'
    config.runtime.pre_start_command = { 'docker', 'compose', 'up', '-d' }

    local pre_start_called = false
    local spawn_called = false

    vim.system = function(cmd, opts, on_exit)
      assert.same({ 'docker', 'compose', 'up', '-d' }, cmd)
      assert.equals(vim.fn.getcwd(), opts.cwd)
      pre_start_called = true
      vim.schedule(function()
        on_exit({ code = 0, stdout = '', stderr = '' })
      end)
      return {
        wait = function()
          return { code = 0, stdout = '', stderr = '' }
        end,
      }
    end

    local fake = {
      url = 'http://127.0.0.1:4000',
      is_running = function()
        return false
      end,
      spawn = function(self, opts)
        spawn_called = true
        vim.schedule(function()
          opts.on_ready({}, self.url)
        end)
      end,
      shutdown = function() end,
    }

    opencode_server.new = function()
      return fake
    end

    local result = server_job.ensure_server():wait()
    assert.same(fake, result)
    assert.is_true(pre_start_called)
    assert.is_true(spawn_called)
  end)

  it('ensure_server rejects when pre_start_command fails', function()
    config.runtime.connection = 'spawn'
    config.runtime.pre_start_command = { 'docker', 'compose', 'up', '-d' }

    vim.system = function(_cmd, _opts, on_exit)
      vim.schedule(function()
        on_exit({ code = 1, stdout = '', stderr = 'compose failed' })
      end)
      return {
        wait = function()
          return { code = 1, stdout = '', stderr = 'compose failed' }
        end,
      }
    end

    local ok = pcall(function()
      server_job.ensure_server():wait()
    end)

    assert.is_false(ok)
  end)

end)
