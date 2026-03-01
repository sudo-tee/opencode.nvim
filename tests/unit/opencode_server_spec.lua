local OpencodeServer = require('opencode.opencode_server')
local config = require('opencode.config')
local assert = require('luassert')

describe('opencode.opencode_server', function()
  local original_system
  local original_runtime

  before_each(function()
    original_system = vim.system
    original_runtime = vim.deepcopy(config.runtime)
  end)

  after_each(function()
    vim.system = original_system
    config.runtime = original_runtime
  end)
  -- Tests for server lifecycle behavior

  it('creates a new server object', function()
    local server = OpencodeServer.new()
    assert.is_table(server)
    assert.is_nil(server.job)
    assert.is_nil(server.url)
    assert.is_nil(server.handle)
    assert.is_false(server.connected)
  end)

  it('connect attaches to remote server and resolves spawn promise', function()
    local server = OpencodeServer.new()
    local connected = server:connect('http://127.0.0.1:9090')

    assert.same(server, connected:wait())
    assert.equals('http://127.0.0.1:9090', server.url)
    assert.is_true(server.connected)
    assert.is_true(server:is_running())
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

  it('spawn resolves when stdout emits host:port without scheme', function()
    local server = OpencodeServer.new()
    local resolved

    vim.system = function(_, opts)
      vim.schedule(function()
        opts.stdout(nil, 'server listening at 127.0.0.1:7999')
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

    assert.equals('http://127.0.0.1:7999', resolved)
  end)

  it('spawn resolves when server URL is split across stdout chunks', function()
    local server = OpencodeServer.new()
    local resolved

    vim.system = function(_, opts)
      vim.schedule(function()
        opts.stdout(nil, 'opencode server li')
        opts.stdout(nil, 'stening on http://127.0.0.1:7878')
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

    assert.equals('http://127.0.0.1:7878', resolved)
  end)

  it('spawn uses configured runtime command and normalizes 0.0.0.0 url', function()
    local server = OpencodeServer.new()
    local captured_cmd
    local captured_opts
    config.runtime.command = { 'wsl.exe', '-e', 'opencode' }

    vim.system = function(cmd, opts)
      captured_cmd = cmd
      captured_opts = opts
      vim.schedule(function()
        opts.stdout(nil, 'opencode server listening on http://0.0.0.0:7777')
      end)
      return { pid = 1, kill = function() end }
    end

    local resolved
    server:spawn({
      cwd = 'C:\\Users\\me\\repo',
      on_ready = function(_, url)
        resolved = url
      end,
      on_error = function() end,
      on_exit = function() end,
    })

    vim.wait(100, function()
      return resolved ~= nil
    end)

    assert.are.same({ 'wsl.exe', '-e', 'opencode', 'serve' }, captured_cmd)
    assert.equals('C:\\Users\\me\\repo', captured_opts.cwd)
    assert.equals('http://127.0.0.1:7777', resolved)
    assert.equals('http://127.0.0.1:7777', server.url)
  end)

  it('uses default runtime command when not overridden', function()
    local server = OpencodeServer.new()
    local captured_cmd
    local captured_opts
    local resolved

    vim.system = function(cmd, opts)
      captured_cmd = cmd
      captured_opts = opts
      vim.schedule(function()
        opts.stdout(nil, 'opencode server listening on http://127.0.0.1:8888')
      end)
      return { pid = 1, kill = function() end }
    end

    server:spawn({
      cwd = '/tmp/workspace',
      on_ready = function(_, url)
        resolved = url
      end,
      on_error = function() end,
      on_exit = function() end,
    })

    vim.wait(100, function()
      return resolved ~= nil
    end)

    assert.equals(config.runtime.command[1], captured_cmd[1])
    assert.equals(config.runtime.serve_args[1], captured_cmd[2])
    assert.equals('/tmp/workspace', captured_opts.cwd)
    assert.equals('http://127.0.0.1:8888', resolved)
  end)

  it('ignores non-fatal stderr before ready and still resolves', function()
    local server = OpencodeServer.new()
    local called = { on_ready = false, on_error = false }

    vim.system = function(cmd, opts)
      vim.schedule(function()
        opts.stderr(nil, 'bash: some profile warning')
        opts.stdout(nil, 'opencode server listening on http://127.0.0.1:7777')
      end)
      return { pid = 1, kill = function() end }
    end

    server:spawn({
      cwd = '.',
      on_ready = function(_, url)
        called.on_ready = true
        assert.equals('http://127.0.0.1:7777', url)
      end,
      on_error = function()
        called.on_error = true
      end,
      on_exit = function() end,
    })

    vim.wait(100, function()
      return called.on_ready
    end)

    assert.is_true(called.on_ready)
    assert.is_false(called.on_error)
  end)

  it('resolves when server url is logged to stderr', function()
    local server = OpencodeServer.new()
    local resolved

    vim.system = function(_, opts)
      vim.schedule(function()
        opts.stderr(nil, 'INFO opencode server listening on http://0.0.0.0:9797')
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

    assert.equals('http://127.0.0.1:9797', resolved)
  end)

  it('shutdown resolves shutdown_promise and clears fields', function()
    local server = OpencodeServer.new()
    local exit_callback
    local original_get_proc_children = vim.api.nvim_get_proc_children

    vim.api.nvim_get_proc_children = function()
      return {}
    end
    
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

    vim.api.nvim_get_proc_children = original_get_proc_children
  end)

  it('calls on_error when stderr callback receives an actual error', function()
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
        assert.equals('some error', err.message)
      end,
      on_exit = function()
        called.on_exit = true
      end,
    })
    -- Simulate stderr callback error
    server.job.stderr({ message = 'some error' }, nil)
    vim.wait(100, function()
      return called.on_error
    end)
    assert.is_true(called.on_error)
  end)

  it('calls on_exit and clears fields when process exits', function()
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
    server.handle = 44
    server:spawn({
      cwd = '.',
      on_ready = function() end,
      on_error = function() end,
      on_exit = function(exit_opts)
        called.on_exit = true
        assert.equals(0, exit_opts.code)
      end,
    })
    -- Simulate exit after job is set
    server.job.exit(0, 0)
    vim.wait(100, function()
      return called.on_exit
    end)
    assert.is_true(called.on_exit)
    assert.is_nil(server.job)
    assert.is_nil(server.url)
    assert.is_nil(server.handle)
  end)

  it('fails startup with timeout when no server url is emitted', function()
    local server = OpencodeServer.new()
    local called = { on_error = false, killed = false }
    config.runtime.startup_timeout_ms = 10

    vim.system = function()
      return {
        pid = 45,
        kill = function()
          called.killed = true
        end,
      }
    end

    server:spawn({
      cwd = '.',
      on_ready = function() end,
      on_error = function(err)
        called.on_error = true
        assert.is_truthy(tostring(err):find('Timed out waiting for opencode server startup', 1, true))
      end,
      on_exit = function() end,
    })

    vim.wait(200, function()
      return called.on_error
    end)

    assert.is_true(called.on_error)
    assert.is_true(called.killed)
  end)

  it('fails startup when startup_timeout_ms is invalid', function()
    local server = OpencodeServer.new()
    local called = { on_error = false }
    config.runtime.startup_timeout_ms = 0

    vim.system = function()
      return {
        pid = 45,
        kill = function() end,
      }
    end

    server:spawn({
      cwd = '.',
      on_ready = function() end,
      on_error = function(err)
        called.on_error = true
        assert.is_truthy(tostring(err):find('runtime.startup_timeout_ms', 1, true))
      end,
      on_exit = function() end,
    })

    vim.wait(100, function()
      return called.on_error
    end)

    assert.is_true(called.on_error)
  end)
end)
