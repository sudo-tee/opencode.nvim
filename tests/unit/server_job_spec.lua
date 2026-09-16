local server_job = require('opencode.server_job')
local Promise = require('opencode.promise')
local curl = require('opencode.curl')
local assert = require('luassert')

describe('server_job', function()
  local original_curl_request
  local opencode_server = require('opencode.opencode_server')
  local original_new
  local original_state_server
  local original_system

  before_each(function()
    original_system = Promise.system
    Promise.system = function(args)
      assert.equals('--help', args[2])
      return Promise.new():resolve({ stdout = 'Commands:\n  opencode serve  starts a headless server', code = 0 })
    end
    original_curl_request = curl.request
    original_new = opencode_server.new
    original_state_server = require('opencode.state').opencode_server
    require('opencode.state').jobs.clear_server()
  end)

  after_each(function()
    Promise.system = original_system
    curl.request = original_curl_request
    opencode_server.new = original_new
    require('opencode.state').jobs.set_server(original_state_server)
  end)

  it('exposes expected public functions', function()
    assert.is_function(server_job.ensure_server)
  end)

  it('ensure_server spawns a new opencode server only once', function()
    local spawn_count = 0
    local fake = {
      url = 'http://127.0.0.1:4000',
      is_ready = function(self)
        return self._ready == true
      end,
      spawn = function(self, opts)
        spawn_count = spawn_count + 1
        vim.schedule(function()
          opts.on_ready({}, self.url)
        end)
      end,
      shutdown = function() end,
      probe_connection = function()
        return Promise.new():resolve({ protocol = 'v1', response = { healthy = true, version = '1.18.30' } })
      end,
      check_health = function()
        return Promise.new():resolve(true)
      end,
      mark_ready = function(self)
        self._ready = true
      end,
      can_release_process = function()
        return true
      end,
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
      original_register = port_mapping.register

      port_mapping.register = function() end

      state.jobs.clear_server()
    end)

    after_each(function()
      config.values.server.port = original_port
      config.values.server.url = original_url
      config.values.server.spawn_command = original_spawn_command
      state.jobs.set_server(original_opencode_server)

      port_mapping.find_any_existing_port = original_find_any_existing_port
      port_mapping.find_port_for_directory = original_find_port_for_directory
      port_mapping.register = original_register
    end)

    it('attaches to custom server when health check succeeds', function()
      config.values.server.url = 'http://192.168.1.100'
      config.values.server.port = 4321
      config.values.server.spawn_command = nil

      curl.request = function(opts)
        vim.schedule(function()
          opts.callback({ status = 200, body = '{"healthy":true,"version":"2.0.1"}' })
        end)
      end

      local result = server_job.ensure_server():wait()
      assert.is_not_nil(result)
      assert.equal('http://192.168.1.100:4321', result.url)
      assert.equal(4321, result.port)
      assert.equal('v2', result.protocol)
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
          opts.callback({ status = 200, body = '{"healthy":true,"version":"2.0.1"}' })
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
        is_ready = function(self)
          return self._ready == true
        end,
        spawn = function(self, opts)
          spawn_count = spawn_count + 1
          vim.schedule(function()
            opts.on_ready({}, self.url)
          end)
        end,
        shutdown = function() end,
        probe_connection = function()
          return Promise.new():resolve({ protocol = 'v1', response = { healthy = true, version = '1.18.30' } })
        end,
        mark_ready = function(self)
          self._ready = true
        end,
        can_release_process = function()
          return true
        end,
      }
      opencode_server.new = function()
        return fake_local
      end

      local result = server_job.ensure_server():wait()
      assert.equal(1, spawn_count)
      assert.same(fake_local, result._value or result)
    end)

    it('generates and reuses a credential when custom spawn has no configured password', function()
      local original_password = config.values.server.password
      local original_username = config.values.server.username
      local original_retry_delay = config.values.server.retry_delay
      local original_password_file = config.values.server.password_file
      config.values.server.url = 'http://127.0.0.1'
      config.values.server.port = 4789
      config.values.server.password = nil
      config.values.server.username = nil
      config.values.server.retry_delay = 0
      config.values.server.password_file = vim.fn.tempname()

      local spawned_env
      config.values.server.spawn_command = function(_, _, env)
        spawned_env = env
      end

      local request_count = 0
      curl.request = function(opts)
        request_count = request_count + 1
        vim.schedule(function()
          if request_count == 1 then
            opts.on_error({ message = 'connection refused' })
          else
            opts.callback({ status = 200, body = '{"healthy":true,"version":"2.0.1"}' })
          end
        end)
      end

      local result = server_job.ensure_server():wait()
      assert.is_not_nil(spawned_env)
      assert.is_string(spawned_env.OPENCODE_PASSWORD)
      assert.equals(spawned_env.OPENCODE_PASSWORD, result.credential.password)
      assert.equals('v2', result.protocol)
      assert.equals(spawned_env.OPENCODE_PASSWORD, vim.fn.readfile(config.values.server.password_file)[1])

      config.values.server.password = original_password
      config.values.server.username = original_username
      config.values.server.retry_delay = original_retry_delay
      config.values.server.password_file = original_password_file
    end)

    it('persists an environment credential before a custom launcher starts', function()
      local original_password = config.values.server.password
      local original_password_file = config.values.server.password_file
      local original_env_password = vim.env.OPENCODE_PASSWORD
      local original_retry_delay = config.values.server.retry_delay
      config.values.server.url = 'http://127.0.0.1'
      config.values.server.port = 4789
      config.values.server.password = nil
      config.values.server.password_file = vim.fn.tempname()
      config.values.server.retry_delay = 0
      vim.env.OPENCODE_PASSWORD = 'environment-password'

      local spawned_env
      config.values.server.spawn_command = function(_, _, env)
        spawned_env = env
      end

      local request_count = 0
      curl.request = function(opts)
        request_count = request_count + 1
        vim.schedule(function()
          if request_count == 1 then
            opts.on_error({ message = 'connection refused' })
          else
            opts.callback({ status = 200, body = '{"healthy":true,"version":"2.0.1"}' })
          end
        end)
      end

      local result = server_job.ensure_server():wait()
      assert.equals('environment-password', spawned_env.OPENCODE_PASSWORD)
      assert.equals('environment-password', result.credential.password)
      assert.equals('environment-password', vim.fn.readfile(config.values.server.password_file)[1])
      assert.equals('rw-------', vim.fn.getfperm(config.values.server.password_file))

      config.values.server.password = original_password
      config.values.server.password_file = original_password_file
      config.values.server.retry_delay = original_retry_delay
      vim.env.OPENCODE_PASSWORD = original_env_password
    end)

    it('surfaces external server failure when health check fails and no spawn_command', function()
      local original_retry_delay = config.values.server.retry_delay
      local original_defer_fn = vim.defer_fn
      config.values.server.url = 'http://192.168.1.100'
      config.values.server.port = 7777
      config.values.server.spawn_command = nil
      config.values.server.retry_delay = 0
      vim.defer_fn = function(fn, _delay)
        vim.schedule(fn)
      end

      curl.request = function(opts)
        vim.schedule(function()
          if opts.callback then
            opts.callback({ status = 503, body = '{}' })
          elseif opts.on_error then
            opts.on_error({ message = 'connection refused' })
          end
        end)
      end

      local ok, err = pcall(function()
        server_job.ensure_server():wait()
      end)
      assert.is_false(ok)
      assert.equals('health probe HTTP 503', err)
      config.values.server.retry_delay = original_retry_delay
      vim.defer_fn = original_defer_fn
    end)

    it('retries transport failures and connects when the server becomes reachable', function()
      local original_auto_kill = config.values.server.auto_kill
      local original_retry_delay = config.values.server.retry_delay
      local original_defer_fn = vim.defer_fn

      config.values.server.url = 'http://192.168.1.100'
      config.values.server.port = 5555
      config.values.server.spawn_command = nil
      config.values.server.auto_kill = false
      config.values.server.retry_delay = 0

      -- Make vim.defer_fn fire immediately so retries don't block
      vim.defer_fn = function(fn, _delay)
        vim.schedule(fn)
      end

      local request_count = 0
      curl.request = function(opts)
        vim.schedule(function()
          request_count = request_count + 1
          if request_count <= 2 then
            opts.on_error({ message = 'connection refused' })
          else
            opts.callback({ status = 200, body = '{"healthy":true,"version":"2.0.1"}' })
          end
        end)
      end

      local result = server_job.ensure_server():wait()
      assert.is_not_nil(result)
      assert.equal('http://192.168.1.100:5555', result.url)
      assert.equal(5555, result.port)
      assert.is_true(request_count >= 3)

      config.values.server.auto_kill = original_auto_kill
      config.values.server.retry_delay = original_retry_delay
      vim.defer_fn = original_defer_fn
    end)

    it('rejects after exhausting transport retries', function()
      local original_auto_kill = config.values.server.auto_kill
      local original_retry_delay = config.values.server.retry_delay
      local original_defer_fn = vim.defer_fn

      config.values.server.url = 'http://192.168.1.100'
      config.values.server.port = 5555
      config.values.server.spawn_command = nil
      config.values.server.auto_kill = false
      config.values.server.retry_delay = 0

      vim.defer_fn = function(fn, _delay)
        vim.schedule(fn)
      end

      curl.request = function(opts)
        vim.schedule(function()
          opts.on_error({ message = 'connection refused' })
        end)
      end

      local ok, err = pcall(function()
        server_job.ensure_server():wait()
      end)

      assert.is_false(ok)
      assert.is_table(err)
      assert.equals('transport', err.kind)
      assert.equals('connection refused', err.cause.message)

      config.values.server.auto_kill = original_auto_kill
      config.values.server.retry_delay = original_retry_delay
      vim.defer_fn = original_defer_fn
    end)

    it('does not spawn local server when auto_kill=false', function()
      local original_auto_kill = config.values.server.auto_kill
      local original_retry_delay = config.values.server.retry_delay
      local original_defer_fn = vim.defer_fn

      config.values.server.url = 'http://192.168.1.100'
      config.values.server.port = 5555
      config.values.server.spawn_command = nil
      config.values.server.auto_kill = false
      config.values.server.retry_delay = 0

      vim.defer_fn = function(fn, _delay)
        vim.schedule(fn)
      end

      -- All attempts fail
      curl.request = function(opts)
        vim.schedule(function()
          opts.callback({ status = 503, body = '{}' })
        end)
      end

      local spawn_count = 0
      opencode_server.new = function()
        return {
          url = 'http://127.0.0.1:8080',
          port = nil,
          is_ready = function()
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
      end

      pcall(function()
        server_job.ensure_server():wait()
      end)

      assert.equal(0, spawn_count)

      config.values.server.auto_kill = original_auto_kill
      config.values.server.retry_delay = original_retry_delay
      vim.defer_fn = original_defer_fn
    end)
  end)

end)

describe('concurrent server startup', function()
  local state = require('opencode.state')
  local config = require('opencode.config')
  local OpencodeServer = require('opencode.opencode_server')
  local port_mapping = require('opencode.port_mapping')
  local original, starts, spawned, callbacks
  before_each(function()
    original = {
      server = state.opencode_server,
      new = OpencodeServer.new,
      probe = OpencodeServer.probe_connection,
      register = port_mapping.register,
      url = config.values.server.url,
      system = Promise.system,
    }
    starts, spawned, callbacks = 0, {}, {}
    Promise.system = function(args)
      assert.equals('--help', args[2])
      return Promise.new():resolve({ stdout = 'Commands:\n  opencode serve  starts a headless server', code = 0 })
    end
    OpencodeServer.probe_connection = function()
      return Promise.new():resolve({ protocol = 'v1', response = { healthy = true, version = '1.18.30' } })
    end
    config.values.server.url = nil
    state.jobs.clear_server()
    port_mapping.register = function() end
    OpencodeServer.new = function()
      local server = { url = nil, _ready = false }
      server.probe_connection = function(self, timeout)
        return OpencodeServer.probe_connection(self, timeout)
      end
      server.is_ready = function(self)
        return self._ready
      end
      server.check_health = function()
        error('startup must finish before health checks run')
      end
      server.mark_ready = function(self)
        self._ready = true
      end
      server.can_release_process = function()
        return true
      end
      server.set_process_release = function() end
      server.release_process = function()
        return true
      end
      server.spawn = function(self, opts)
        starts = starts + 1
        self.job = { pid = 123 }
        spawned[#spawned + 1], callbacks[#callbacks + 1] = self, opts
      end
      return server
    end
  end)
  after_each(function()
    state.jobs.set_server(original.server)
    Promise.system = original.system
    OpencodeServer.new, OpencodeServer.probe_connection, port_mapping.register =
      original.new, original.probe, original.register
    config.values.server.url = original.url
  end)
  local function ready(index)
    local server = spawned[index]
    server.url = 'http://127.0.0.1:4096'
    callbacks[index].on_ready(server.job, server.url)
  end
  it('shares a single startup between lifecycle callers', function()
    local panel = server_job.ensure_server()
    local another_panel = server_job.ensure_server()
    assert.is_true(vim.wait(1000, function()
      return starts == 1
    end))
    assert.equals(1, starts)
    assert.equals(panel, another_panel)
    assert.is_false(panel:is_resolved())
    ready(1)
    assert.equals(spawned[1], panel:wait())
  end)
  it('reuses the successful startup probe for immediately following operations', function()
    local connection = server_job.ensure_server()
    assert.is_true(vim.wait(1000, function() return starts == 1 end))
    ready(1)
    assert.equals(spawned[1], connection:wait())
    assert.equals(spawned[1], server_job.ensure_server():wait())
  end)

  for _, kind in ipairs({ 'transport', 'identity_changed' }) do
    it('reconnects after a cached server reports ' .. kind, function()
      state.jobs.set_server({
        is_ready = function() return true end,
        check_health = function() return Promise.new():reject({ kind = kind }) end,
      })
      local connection = server_job.ensure_server({ force_health_check = true })
      assert.is_true(vim.wait(1000, function() return starts == 1 end))
      ready(1)
      assert.equals(spawned[1], connection:wait())
      assert.equals(1, starts)
    end)
  end

  it('publishes a directly spawned process only after protocol probe succeeds', function()
    local probe = Promise.new()
    OpencodeServer.probe_connection = function()
      return probe
    end
    local direct = Promise.new()
    server_job.spawn_local_server(direct)
    assert.equals(1, starts)
    ready(1)
    assert.is_nil(state.opencode_server)
    assert.is_false(direct:is_resolved())
    probe:resolve({ protocol = 'v1', response = { healthy = true, version = '1.18.30' } })
    assert.equals(spawned[1], direct:wait())
    assert.equals(spawned[1], state.opencode_server)
  end)
  it('releases failed startup so the next request can retry', function()
    local first = server_job.ensure_server()
    assert.is_true(vim.wait(1000, function()
      return starts == 1
    end))
    spawned[1].job = nil
    callbacks[1].on_error('address already in use')
    assert.is_false(pcall(function()
      first:wait()
    end))
    local second = server_job.ensure_server()
    assert.is_true(vim.wait(1000, function()
      return starts == 2
    end))
    assert.equals(2, starts)
    ready(2)
    assert.equals(spawned[2], second:wait())
  end)
end)

describe('cached connection health', function()
  local state = require('opencode.state')
  local config = require('opencode.config')
  local original_server, original_ttl, server, probes, health

  before_each(function()
    original_server = state.opencode_server
    original_ttl = config.values.server.health_check_ttl_ms
    config.values.server.health_check_ttl_ms = 5000
    probes = 0
    health = Promise.new():resolve(true)
    server = {
      is_ready = function() return true end,
      check_health = function()
        probes = probes + 1
        return health
      end,
    }
    state.jobs.set_server(server)
  end)

  after_each(function()
    state.jobs.set_server(original_server)
    config.values.server.health_check_ttl_ms = original_ttl
  end)

  it('reuses a recently checked connection without probing again', function()
    assert.equals(server, server_job.ensure_server():wait())
    assert.equals(server, server_job.ensure_server():wait())
    assert.equals(1, probes)
  end)

  it('allows an explicit health check before the TTL expires', function()
    server_job.ensure_server():wait()
    assert.equals(server, server_job.ensure_server({ force_health_check = true }):wait())
    assert.equals(2, probes)
  end)

  it('shares an expired health check between callers', function()
    server_job.ensure_server():wait()
    config.values.server.health_check_ttl_ms = 0
    health = Promise.new()
    local first = server_job.ensure_server()
    local second = server_job.ensure_server()
    assert.equals(first, second)
    assert.is_true(vim.wait(1000, function() return probes == 2 end))
    health:resolve(true)
    assert.equals(server, first:wait())
    assert.equals(2, probes)
  end)

  it('validates a replacement connection when the server changes during a health check', function()
    health = Promise.new()
    local connection = server_job.ensure_server()
    assert.is_true(vim.wait(1000, function() return probes == 1 end))
    local replacement_probes = 0
    local replacement = {
      is_ready = function() return true end,
      check_health = function()
        replacement_probes = replacement_probes + 1
        return Promise.new():resolve(true)
      end,
    }
    state.jobs.set_server(replacement)
    health:reject({ kind = 'credentials', message = 'old connection failed' })
    assert.equals(replacement, connection:wait())
    assert.equals(1, replacement_probes)
    assert.equals(replacement, state.opencode_server)
  end)

  it('keeps credential failures visible', function()
    health = Promise.new():reject({ kind = 'credentials', message = 'unauthorized' })
    local ok, err = pcall(function() server_job.ensure_server():wait() end)
    assert.is_false(ok)
    assert.equals('credentials', err.kind)
    assert.equals(server, state.opencode_server)
  end)
end)
