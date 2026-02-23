local OpencodeServer = require('opencode.opencode_server')
local assert = require('luassert')

describe('opencode.opencode_server', function()
  local original_system
  before_each(function()
    original_system = vim.system
  end)
  after_each(function()
    vim.system = original_system
  end)
  -- Tests for server lifecycle behavior

  it('creates a new server object', function()
    local server = OpencodeServer.new()
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

  it('calls on_error when stderr is triggered', function()
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
        assert.equals('some error', err)
      end,
      on_exit = function()
        called.on_exit = true
      end,
    })
    -- Simulate stderr after job is set
    server.job.stderr(nil, 'some error')
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

  describe('external server support', function()
    it('creates an external server instance with from_external', function()
      local server = OpencodeServer.from_external('http://192.168.1.100:8080')
      assert.is_table(server)
      assert.is_nil(server.job) -- No local job
      assert.equals('http://192.168.1.100:8080', server.url)
      assert.is_nil(server.handle)
      
      -- Spawn promise should already be resolved
      local resolved = false
      server:get_spawn_promise():and_then(function()
        resolved = true
      end)
      vim.wait(10, function()
        return resolved
      end)
      assert.is_true(resolved)
    end)

    it('is_running returns true for external server with URL', function()
      local server = OpencodeServer.from_external('http://localhost:8080')
      assert.is_true(server:is_running())
    end)

    it('is_running returns false for external server without URL', function()
      local server = OpencodeServer.from_external('http://localhost:8080')
      server.url = nil
      assert.is_false(server:is_running())
    end)

    it('shutdown clears external server without killing process', function()
      local server = OpencodeServer.from_external('http://localhost:8080')
      local resolved = false
      
      server:get_shutdown_promise():and_then(function()
        resolved = true
      end)
      
      server:shutdown()
      
      vim.wait(10, function()
        return resolved
      end)
      
      assert.is_true(resolved)
      assert.is_nil(server.url)
      assert.is_nil(server.handle)
      assert.is_nil(server.job) -- Should remain nil, no process was killed
    end)
  end)
end)
