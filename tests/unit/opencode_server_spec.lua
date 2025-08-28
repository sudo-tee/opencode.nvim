local OpencodeServer = require('opencode.opencode_server')
local assert = require('luassert')

describe('opencode.opencode_server', function()
  -- Remove after_each restoration to maintain global mock for preventing real server spawning

  it('creates a new server object', function()
    local server = OpencodeServer.new()
    assert.is_table(server)
    assert.is_nil(server.job)
    assert.is_nil(server.url)
    assert.is_nil(server.handle)
  end)

  it('spawns the server and calls on_ready when URL is found', function()
    local called = { on_ready = false }
    local test_url = 'http://localhost:1234'
    local opts_captured = {}
    vim.system = function(cmd, opts)
      opts_captured.stdout = opts.stdout
      opts_captured.stderr = opts.stderr
      opts_captured.exit = opts.exit
      return {
        pid = 42,
        kill = function()
          called.killed = true
        end,
        stdout = function(err, data)
          opts_captured.stdout(err, data)
        end,
        stderr = function(err, data)
          if opts_captured.stderr then
            opts_captured.stderr(err, data)
          end
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
      on_ready = function(job, url)
        called.on_ready = true
        assert.is_table(job)
        assert.equals(test_url, url)
      end,
      on_error = function()
        called.on_error = true
      end,
      on_exit = function()
        called.on_exit = true
      end,
    })
    -- Simulate stdout after job is set
    server.job.stdout(nil, 'opencode server listening on ' .. test_url)
    vim.wait(100, function()
      return called.on_ready
    end)
    assert.is_true(called.on_ready)
    assert.equals(test_url, server.url)
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
    vim.system = function(cmd, opts)
      opts_captured.stdout = opts.stdout
      opts_captured.stderr = opts.stderr
      opts_captured.exit = opts.exit
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
          opts_captured.exit(code, signal)
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
      on_exit = function(code)
        called.on_exit = true
        assert.equals(0, code)
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

  -- it('shutdown clears fields and calls kill if job exists', function()
  --   local killed = false
  --   local server = OpencodeServer.new()
  --   server.job = {
  --     pid = 55,
  --     kill = function()
  --       killed = true
  --     end,
  --   }
  --   server.url = 'http://localhost:9999'
  --   server.handle = 55
  --   server:shutdown()
  --   assert.is_nil(server.job)
  --   assert.is_nil(server.url)
  --   assert.is_nil(server.handle)
  --   assert.is_true(killed)
  -- end)
end)
