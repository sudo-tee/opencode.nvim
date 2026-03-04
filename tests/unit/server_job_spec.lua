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
    local fake = {
      url = 'http://127.0.0.1:4000',
      is_running = function()
        return spawn_count > 0
      end,
      spawn = function(self, opts)
        spawn_count = spawn_count + 1
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
  end)

  describe('ensure_server with config.server.url set', function()
    local config
    local state
    local port_mapping
    local original_port
    local original_url
    local original_spawn_command
    local original_opencode_server
    local original_find_any_existing_port
    local original_find_port_for_directory
    local original_started_by_nvim
    local original_register

    before_each(function()
      config = require('opencode.config')
      state = require('opencode.state')
      port_mapping = require('opencode.port_mapping')

      original_port = config.values.server.port
      original_url = config.values.server.url
      original_spawn_command = config.values.server.spawn_command
      original_opencode_server = state.opencode_server

      original_find_any_existing_port = port_mapping.find_any_existing_port
      original_find_port_for_directory = port_mapping.find_port_for_directory
      original_started_by_nvim = port_mapping.started_by_nvim
      original_register = port_mapping.register

      port_mapping.register = function() end
      port_mapping.started_by_nvim = function()
        return false
      end

      state.opencode_server = nil
    end)

    after_each(function()
      config.values.server.port = original_port
      config.values.server.url = original_url
      config.values.server.spawn_command = original_spawn_command
      state.opencode_server = original_opencode_server

      port_mapping.find_any_existing_port = original_find_any_existing_port
      port_mapping.find_port_for_directory = original_find_port_for_directory
      port_mapping.started_by_nvim = original_started_by_nvim
      port_mapping.register = original_register
    end)

    it('attaches to custom server when health check succeeds', function()
      config.values.server.url = 'http://192.168.1.100'
      config.values.server.port = 4321
      config.values.server.spawn_command = nil

      curl.request = function(opts)
        vim.schedule(function()
          opts.callback({ status = 200, body = '{"ok":true}' })
        end)
      end

      local result = server_job.ensure_server():wait()
      assert.is_not_nil(result)
      assert.equal('http://192.168.1.100:4321', result.url)
      assert.equal(4321, result.port)
    end)

    it('resolves url with default port from find_any_existing_port when port is nil', function()
      config.values.server.url = 'http://127.0.0.1'
      config.values.server.port = nil
      config.values.server.spawn_command = nil

      port_mapping.find_any_existing_port = function()
        return 9999
      end

      curl.request = function(opts)
        vim.schedule(function()
          opts.callback({ status = 200, body = '{"ok":true}' })
        end)
      end

      local result = server_job.ensure_server():wait()
      assert.is_not_nil(result)
      assert.equal('http://127.0.0.1:9999', result.url)
    end)

    it('falls back to local spawn when resolve_port returns nil', function()
      config.values.server.url = 'http://127.0.0.1'
      config.values.server.port = nil
      config.values.server.spawn_command = nil

      -- no existing port → resolve_port() returns nil
      port_mapping.find_any_existing_port = function()
        return nil
      end

      local spawn_count = 0
      local fake_local = {
        url = 'http://127.0.0.1:5000',
        port = nil,
        is_running = function(self)
          return spawn_count > 0
        end,
        spawn = function(self, opts)
          spawn_count = spawn_count + 1
          vim.schedule(function()
            opts.on_ready({}, self.url)
          end)
        end,
        shutdown = function() end,
      }
      opencode_server.new = function()
        return fake_local
      end

      local result = server_job.ensure_server():wait()
      assert.equal(1, spawn_count)
      assert.same(fake_local, result._value or result)
    end)

    it('falls back to local spawn when health check fails and no spawn_command', function()
      config.values.server.url = 'http://192.168.1.100'
      config.values.server.port = 7777
      config.values.server.spawn_command = nil

      curl.request = function(opts)
        vim.schedule(function()
          if opts.callback then
            opts.callback({ status = 503, body = '{}' })
          elseif opts.on_error then
            opts.on_error({ message = 'connection refused' })
          end
        end)
      end

      local spawn_count = 0
      local fake_local = {
        url = 'http://127.0.0.1:8080',
        port = nil,
        is_running = function(self)
          return spawn_count > 0
        end,
        spawn = function(self, opts)
          spawn_count = spawn_count + 1
          vim.schedule(function()
            opts.on_ready({}, self.url)
          end)
        end,
        shutdown = function() end,
      }
      opencode_server.new = function()
        return fake_local
      end

      local result = server_job.ensure_server():wait()
      assert.equal(1, spawn_count)
      assert.same(fake_local, result._value or result)
    end)
  end)
end)
