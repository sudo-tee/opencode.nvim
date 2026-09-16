local OpencodeServer = require('opencode.opencode_server')
local curl = require('opencode.curl')
local assert = require('luassert')
local port_mapping = require('opencode.port_mapping')

local function set_identity(server, version, pid)
  server.version = version
  server.server_identity = { version = version, pid = pid }
end

describe('opencode.opencode_server', function()
  local original_system
  local original_curl_request
  local original_kill
  local original_get_children
  local original_unregister
  before_each(function()
    original_kill = vim.uv.kill
    original_get_children = vim.api.nvim_get_proc_children
    -- Fake job PIDs must never reach the operating system.
    vim.uv.kill = function()
      return true
    end
    vim.api.nvim_get_proc_children = function()
      return {}
    end
    original_system = vim.system
    original_curl_request = curl.request
    original_unregister = port_mapping.unregister
  end)
  after_each(function()
    vim.uv.kill = original_kill
    vim.api.nvim_get_proc_children = original_get_children
    vim.system = original_system
    curl.request = original_curl_request
    port_mapping.unregister = original_unregister
  end)
  -- Tests for server lifecycle behavior

  it('creates a new server object', function()
    local server = OpencodeServer.new()
    server.credential = { username = 'admin', password = 'secret' }
    assert.is_table(server)
    assert.is_nil(server.job)
    assert.is_nil(server.url)
    assert.is_nil(server.handle)
  end)

  it('spawn promise resolves when stdout emits server URL', function()
    local server = OpencodeServer.new()
    local resolved
    vim.system = function(cmd, opts)
      -- Simulate server output asynchronously
      vim.schedule(function()
        opts.stdout(nil, 'opencode server listening on http://127.0.0.1:7777')
      end)
      return { pid = 1, kill = function() end }
    end
    server:spawn({
      cwd = '.',
      on_ready = function(_, url)
        resolved = url
      end,
      on_error = function() end,
      on_exit = function() end,
    })
    vim.wait(100, function()
      return resolved ~= nil
    end)
    assert.equals('http://127.0.0.1:7777', resolved)
    assert.equals('http://127.0.0.1:7777', server.url)
  end)

  it('spawn passes auth env vars to vim.system when password is configured', function()
    local config = require('opencode.config')
    local auth = require('opencode.auth')
    local original_password = config.values.server.password
    local original_username = config.values.server.username
    config.values.server.password = 'secret'
    config.values.server.username = 'admin'

    local captured_opts
    vim.system = function(cmd, opts)
      captured_opts = opts
      vim.schedule(function()
        opts.stdout(nil, 'opencode server listening on http://127.0.0.1:7777')
      end)
      return { pid = 1, kill = function() end }
    end

    local server = OpencodeServer.new()
    server.credential = { username = 'admin', password = 'secret' }
    server:spawn({
      cwd = '.',
      on_ready = function() end,
      on_error = function() end,
      on_exit = function() end,
    })

    vim.wait(100, function()
      return captured_opts ~= nil
    end)

    assert.is_not_nil(captured_opts)
    assert.is_not_nil(captured_opts.env)
    assert.equals('secret', captured_opts.env.OPENCODE_SERVER_PASSWORD)
    assert.equals('admin', captured_opts.env.OPENCODE_SERVER_USERNAME)

    config.values.server.password = original_password
    config.values.server.username = original_username
  end)

  it('spawn passes empty env when no password is configured', function()
    local config = require('opencode.config')
    local auth = require('opencode.auth')
    local original_password = config.values.server.password
    local original_env_password = vim.env.OPENCODE_SERVER_PASSWORD
    local original_env_username = vim.env.OPENCODE_SERVER_USERNAME
    config.values.server.password = nil
    vim.env.OPENCODE_SERVER_PASSWORD = nil
    vim.env.OPENCODE_SERVER_USERNAME = nil

    local captured_opts
    vim.system = function(cmd, opts)
      captured_opts = opts
      vim.schedule(function()
        opts.stdout(nil, 'opencode server listening on http://127.0.0.1:7777')
      end)
      return { pid = 1, kill = function() end }
    end

    local server = OpencodeServer.new()
    server:spawn({
      cwd = '.',
      on_ready = function() end,
      on_error = function() end,
      on_exit = function() end,
    })

    vim.wait(100, function()
      return captured_opts ~= nil
    end)

    assert.is_not_nil(captured_opts)
    assert.same({}, captured_opts.env)

    config.values.server.password = original_password
    if original_env_password then
      vim.env.OPENCODE_SERVER_PASSWORD = original_env_password
    else
      vim.env.OPENCODE_SERVER_PASSWORD = nil
    end
    if original_env_username then
      vim.env.OPENCODE_SERVER_USERNAME = original_env_username
    else
      vim.env.OPENCODE_SERVER_USERNAME = nil
    end
  end)

  it('shutdown resolves shutdown_promise and clears fields', function()
    local server = OpencodeServer.new()
    local exit_callback

    -- Mock vim.system to capture the exit callback
    vim.system = function(cmd, opts, on_exit)
      exit_callback = on_exit
      return { pid = 2, kill = function() end }
    end

    -- Spawn the server so the exit callback is set up
    server:spawn({
      cwd = '.',
      on_ready = function() end,
      on_error = function() end,
      on_exit = function() end,
    })

    local resolved = false
    server:get_shutdown_promise():and_then(function()
      resolved = true
    end)

    -- Call shutdown (sends SIGTERM)
    server:shutdown()

    -- Simulate the process exiting by calling the exit callback
    vim.schedule(function()
      exit_callback({ code = 0, signal = 0 })
    end)

    vim.wait(100, function()
      return resolved
    end)

    assert.is_true(resolved)
    assert.is_nil(server.job)
    assert.is_nil(server.url)
    assert.is_nil(server.handle)
  end)

  it('calls on_error when stderr callback receives an error', function()
    local called = { on_error = false }
    local opts_captured = {}
    vim.system = function(cmd, opts)
      opts_captured.stdout = opts.stdout
      opts_captured.stderr = opts.stderr
      opts_captured.exit = opts.exit
      return {
        pid = 43,
        kill = function()
          called.killed = true
        end,
        stdout = function(err, data)
          if opts_captured.stdout then
            opts_captured.stdout(err, data)
          end
        end,
        stderr = function(err, data)
          opts_captured.stderr(err, data)
        end,
        exit = function(code, signal)
          if opts_captured.exit then
            opts_captured.exit(code, signal)
          end
        end,
      }
    end
    local server = OpencodeServer.new()
    server:spawn({
      cwd = '.',
      on_ready = function()
        called.on_ready = true
      end,
      on_error = function(err)
        called.on_error = true
        assert.equals('stream error', err)
      end,
      on_exit = function()
        called.on_exit = true
      end,
    })
    -- Simulate stderr callback error after job is set
    server.job.stderr('stream error', nil)
    vim.wait(100, function()
      return called.on_error
    end)
    assert.is_true(called.on_error)
  end)

  it('ignores stderr output before ready when stdout later reports the server URL', function()
    local called = { on_error = false }
    local server = OpencodeServer.new()

    vim.system = function(cmd, opts)
      vim.schedule(function()
        opts.stderr(nil, 'Performing one time database migration, may take a few minutes...\n')
        opts.stderr(nil, 'sqlite-migration:100\n')
        opts.stdout(nil, 'opencode server listening on http://127.0.0.1:7777')
      end)

      return { pid = 45, kill = function() end }
    end

    local resolved
    server:spawn({
      cwd = '.',
      on_ready = function(_, url)
        resolved = url
      end,
      on_error = function()
        called.on_error = true
      end,
      on_exit = function() end,
    })

    vim.wait(100, function()
      return resolved ~= nil
    end)

    assert.equals('http://127.0.0.1:7777', resolved)
    assert.is_false(called.on_error)
  end)

  it('reports startup failure if the process exits before reporting the server URL', function()
    local called = { on_error = nil, on_exit = false }
    local server = OpencodeServer.new()

    vim.system = function(cmd, opts, on_exit)
      vim.schedule(function()
        opts.stderr(nil, 'Database migration failed.\n')
        on_exit({ code = 1, signal = 0 })
      end)

      return { pid = 46, kill = function() end }
    end

    server:spawn({
      cwd = '.',
      on_ready = function()
        called.on_ready = true
      end,
      on_error = function(err)
        called.on_error = err
      end,
      on_exit = function()
        called.on_exit = true
      end,
    })

    vim.wait(100, function()
      return called.on_exit
    end)
    assert.truthy(tostring(called.on_error):match('Database migration failed'))
    assert.is_true(called.on_exit)
  end)

  it('calls on_exit and preserves connection identity when process exits', function()
    local called = { on_exit = false }
    local opts_captured = {}
    vim.system = function(cmd, opts, on_exit)
      opts_captured.stdout = opts.stdout
      opts_captured.stderr = opts.stderr
      opts_captured.exit = on_exit
      return {
        pid = 44,
        kill = function()
          called.killed = true
        end,
        stdout = function(err, data)
          if opts_captured.stdout then
            opts_captured.stdout(err, data)
          end
        end,
        stderr = function(err, data)
          if opts_captured.stderr then
            opts_captured.stderr(err, data)
          end
        end,
        exit = function(code, signal)
          opts_captured.exit({ code = code, signal = signal })
        end,
      }
    end
    local server = OpencodeServer.new()
    server.job = { pid = 44 }
    server.url = 'http://localhost:5678'
    server.port = 5678
    server.handle = 44
    server.protocol = 'v2'
    set_identity(server, '2.0.1', 44)
    server.credential = { username = 'opencode', password = 'secret' }
    server:spawn({
      cwd = '.',
      on_ready = function() end,
      on_error = function() end,
      on_exit = function(exit_opts)
        called.on_exit = true
        assert.equals(0, exit_opts.code)
      end,
    })
    server:mark_ready()
    local stream_closed = false
    server:set_stream({
      shutdown = function()
        stream_closed = true
      end,
    })
    local unregistered
    port_mapping.unregister = function(port, connection)
      unregistered = { port = port, connection = connection }
      return true
    end
    -- Simulate exit after job is set
    server.job.exit(0, 0)
    vim.wait(100, function()
      return called.on_exit
    end)
    assert.is_true(called.on_exit)
    assert.is_nil(server.job)
    assert.equals('http://localhost:5678', server.url)
    assert.equals('v2', server.protocol)
    assert.equals('2.0.1', server.version)
    assert.same({ username = 'opencode', password = 'secret' }, server.credential)
    assert.is_true(stream_closed)
    assert.same({ port = 5678, connection = server }, unregistered)
    assert.is_false(server:is_ready())
    assert.is_nil(server.handle)
    assert.is_true(server:get_shutdown_promise():is_resolved())
  end)

  describe('custom server support', function()
    it('creates a custom server instance with from_custom', function()
      local server = OpencodeServer.from_custom('http://192.168.1.100:8080')
      assert.is_table(server)
      assert.is_nil(server.job) -- No local job
      assert.equals('http://192.168.1.100:8080', server.url)
      assert.is_nil(server.handle)
    end)

    it('becomes ready only after the custom connection is published', function()
      local server = OpencodeServer.from_custom('http://localhost:8080')
      assert.is_false(server:is_ready())
      server.protocol = 'v1'
      set_identity(server, '1.18.30')
      server.credential = { username = 'opencode' }
      server:mark_ready()
      assert.is_true(server:is_ready())
    end)

    it('close releases SSE and rejects a later stream for an attached server', function()
      local server = OpencodeServer.from_custom('http://localhost:8080')
      server.protocol = 'v2'
      set_identity(server, '2.0.1')
      server.credential = { username = 'opencode', password = 'secret' }
      server:mark_ready()
      local io_closed = false
      server:set_stream({
        shutdown = function()
          io_closed = true
        end,
      })

      assert.is_true(server:close():wait())
      assert.is_true(io_closed)
      assert.is_true(server:get_shutdown_promise():is_resolved())
      assert.equals('http://localhost:8080', server.url)
      assert.is_false(server:is_ready())
      assert.is_nil(server.handle)
      assert.is_nil(server.job)
      local late_closed = false
      assert.is_false(pcall(function()
        server:set_stream({
          shutdown = function()
            late_closed = true
          end,
        })
      end))
      assert.is_true(late_closed)
    end)
  end)

  it('rejects a changed server identity without mutating the ready connection', function()
    local server = OpencodeServer.from_custom('http://localhost:8080')
    server.protocol = 'v2'
    set_identity(server, '2.0.1')
    server.credential = { username = 'opencode', password = 'secret' }
    server:mark_ready()
    curl.request = function(opts)
      vim.schedule(function()
        opts.callback({ status = 200, body = '{"healthy":true,"version":"2.0.2"}' })
      end)
    end

    local ok, err = pcall(function()
      server:check_health():wait()
    end)

    assert.is_false(ok)
    assert.equals('identity_changed', err.kind)
    assert.equals('v2', server.protocol)
    assert.equals('2.0.1', server.version)
    assert.equals('http://localhost:8080', server.url)
    assert.is_true(server:is_ready())
  end)

  it('runs the acquired process release once without clearing connection identity', function()
    local killed = {}
    vim.uv.kill = function(pid, signal)
      killed[#killed + 1] = { pid = pid, signal = signal }
      return 0
    end
    local server = OpencodeServer.from_custom('http://localhost:8080')
    server.protocol = 'v2'
    set_identity(server, '2.0.1', 43210)
    server.credential = { username = 'opencode', password = 'secret' }
    server.custom_pid = 43210
    server:set_process_release(function()
      require('opencode.util').kill_pid(43210)
    end)
    server:mark_ready()

    assert.is_true(server:close():wait())
    assert.is_true(server:close():wait())

    assert.same({ { pid = 43210, signal = 15 }, { pid = 43210, signal = 9 } }, killed)
    assert.equals('http://localhost:8080', server.url)
    assert.equals('v2', server.protocol)
    assert.equals('2.0.1', server.version)
    assert.is_false(server:is_ready())
  end)

  describe('kill_pid', function()
    it('sends SIGTERM then SIGKILL to the given pid', function()
      local killed = {}
      local original_kill = vim.uv.kill
      vim.uv.kill = function(pid, signal)
        table.insert(killed, { pid = pid, signal = signal })
        return true
      end
      local original_children = vim.api.nvim_get_proc_children
      vim.api.nvim_get_proc_children = function(_)
        return {}
      end

      require('opencode.util').kill_pid(42)

      vim.uv.kill = original_kill
      vim.api.nvim_get_proc_children = original_children

      assert.equals(2, #killed)
      assert.same({ pid = 42, signal = 15 }, killed[1])
      assert.same({ pid = 42, signal = 9 }, killed[2])
    end)

    it('kills children before the parent', function()
      local kill_order = {}
      local original_kill = vim.uv.kill
      vim.uv.kill = function(pid, signal)
        table.insert(kill_order, { pid = pid, signal = signal })
        return true
      end
      local original_children = vim.api.nvim_get_proc_children
      vim.api.nvim_get_proc_children = function(_)
        return { 10, 11 }
      end

      require('opencode.util').kill_pid(99)

      vim.uv.kill = original_kill
      vim.api.nvim_get_proc_children = original_children

      -- children (SIGTERM+SIGKILL each) then parent (SIGTERM+SIGKILL)
      assert.equals(6, #kill_order)
      assert.same({ pid = 10, signal = 15 }, kill_order[1])
      assert.same({ pid = 10, signal = 9 }, kill_order[2])
      assert.same({ pid = 11, signal = 15 }, kill_order[3])
      assert.same({ pid = 11, signal = 9 }, kill_order[4])
      assert.same({ pid = 99, signal = 15 }, kill_order[5])
      assert.same({ pid = 99, signal = 9 }, kill_order[6])
    end)
  end)

  describe('authentication headers', function()
    local config
    local auth = require('opencode.auth')
    local original_password
    local original_username
    local original_env_password
    local original_env_username

    before_each(function()
      config = require('opencode.config')
      original_password = config.values.server.password
      original_username = config.values.server.username
      original_env_password = vim.env.OPENCODE_SERVER_PASSWORD
      original_env_username = vim.env.OPENCODE_SERVER_USERNAME
      config.values.server.password = nil
      config.values.server.username = nil
      vim.env.OPENCODE_SERVER_PASSWORD = nil
      vim.env.OPENCODE_SERVER_USERNAME = nil
    end)

    after_each(function()
      config.values.server.password = original_password
      config.values.server.username = original_username
      if original_env_password then
        vim.env.OPENCODE_SERVER_PASSWORD = original_env_password
      else
        vim.env.OPENCODE_SERVER_PASSWORD = nil
      end
      if original_env_username then
        vim.env.OPENCODE_SERVER_USERNAME = original_env_username
      else
        vim.env.OPENCODE_SERVER_USERNAME = nil
      end
    end)

    it('connection probe includes Authorization header when password is set', function()
      config.values.server.password = 'secret'
      local captured
      curl.request = function(opts)
        captured = opts
      end

      local server = OpencodeServer.from_custom('http://127.0.0.1:3000')
      server.credential = { username = 'opencode', password = 'secret' }
      server:probe_connection(2000)

      assert.is_not_nil(captured)
      assert.is_not_nil(captured.headers)
      assert.truthy(vim.startswith(captured.headers['Authorization'], 'Basic '))
    end)

    it('connection probe does not include Authorization header when no password', function()
      local captured
      curl.request = function(opts)
        captured = opts
      end

      local server = OpencodeServer.from_custom('http://127.0.0.1:3000')
      server.credential = { username = 'opencode' }
      server:probe_connection(2000)

      assert.is_not_nil(captured)
      assert.is_nil(captured.headers['Authorization'])
    end)
  end)
end)
