local OpencodeServer = require('opencode.opencode_server')
local assert = require('luassert')

describe('opencode.opencode_server', function()
  local original_uv_spawn
  local original_uv_new_pipe
  local original_uv_kill
  
  before_each(function()
    original_uv_spawn = vim.uv.spawn
    original_uv_new_pipe = vim.uv.new_pipe
    original_uv_kill = vim.uv.kill
  end)
  
  after_each(function()
    vim.uv.spawn = original_uv_spawn
    vim.uv.new_pipe = original_uv_new_pipe
    vim.uv.kill = original_uv_kill
  end)
  
  -- Helper to create mock pipe
  local function create_mock_pipe()
    local read_callback
    return {
      read_start = function(self, callback)
        read_callback = callback
        return self
      end,
      read_stop = function(self)
        return self
      end,
      close = function(self) end,
      is_closing = function()
        return false
      end,
      trigger_read = function(err, data)
        if read_callback then
          read_callback(err, data)
        end
      end,
    }
  end

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
    local stdout_pipe = create_mock_pipe()
    local stderr_pipe = create_mock_pipe()
    local exit_callback
    
    vim.uv.new_pipe = function()
      if not stdout_pipe._used then
        stdout_pipe._used = true
        return stdout_pipe
      else
        return stderr_pipe
      end
    end
    
    vim.uv.spawn = function(cmd, opts, callback)
      exit_callback = callback
      return {
        is_closing = function()
          return false
        end,
        close = function() end,
      }, 1
    end
    
    server:spawn({
      cwd = '.',
      on_ready = function(_, url)
        resolved = url
      end,
      on_error = function() end,
      on_exit = function() end,
    })
    
    -- Simulate server output asynchronously
    vim.schedule(function()
      stdout_pipe.trigger_read(nil, 'opencode server listening on http://127.0.0.1:7777')
    end)
    
    vim.wait(100, function()
      return resolved ~= nil
    end)
    
    assert.equals('http://127.0.0.1:7777', resolved)
    assert.equals('http://127.0.0.1:7777', server.url)
  end)

  it('shutdown resolves shutdown_promise and clears fields', function()
    local server = OpencodeServer.new()
    local stdout_pipe = create_mock_pipe()
    local stderr_pipe = create_mock_pipe()
    local exit_callback
    local process_handle = {
      is_closing = function()
        return false
      end,
      close = function() end,
    }
    
    vim.uv.new_pipe = function()
      if not stdout_pipe._used then
        stdout_pipe._used = true
        return stdout_pipe
      else
        return stderr_pipe
      end
    end
    
    vim.uv.spawn = function(cmd, opts, callback)
      exit_callback = callback
      return process_handle, 2
    end
    
    vim.uv.kill = function()
      return true
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
    
    -- Call shutdown (sends SIGTERM/SIGKILL)
    server:shutdown()
    
    -- Simulate the process exiting by calling the exit callback
    if exit_callback then
      vim.schedule(function()
        exit_callback(0, 0)
      end)
    end
    
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
    local stdout_pipe = create_mock_pipe()
    local stderr_pipe = create_mock_pipe()
    local exit_callback
    
    vim.uv.new_pipe = function()
      if not stdout_pipe._used then
        stdout_pipe._used = true
        return stdout_pipe
      else
        return stderr_pipe
      end
    end
    
    vim.uv.spawn = function(cmd, opts, callback)
      exit_callback = callback
      return {
        is_closing = function()
          return false
        end,
        close = function() end,
      }, 43
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
    
    -- Simulate stderr after spawn
    vim.schedule(function()
      stderr_pipe.trigger_read(nil, 'some error')
    end)
    
    vim.wait(100, function()
      return called.on_error
    end)
    
    assert.is_true(called.on_error)
  end)

  it('calls on_exit and clears fields when process exits', function()
    local called = { on_exit = false }
    local stdout_pipe = create_mock_pipe()
    local stderr_pipe = create_mock_pipe()
    local exit_callback
    
    vim.uv.new_pipe = function()
      if not stdout_pipe._used then
        stdout_pipe._used = true
        return stdout_pipe
      else
        return stderr_pipe
      end
    end
    
    vim.uv.spawn = function(cmd, opts, callback)
      exit_callback = callback
      return {
        is_closing = function()
          return false
        end,
        close = function() end,
      }, 44
    end
    
    local server = OpencodeServer.new()
    server:spawn({
      cwd = '.',
      on_ready = function() end,
      on_error = function() end,
      on_exit = function(exit_opts)
        called.on_exit = true
        assert.equals(0, exit_opts.code)
      end,
    })
    
    -- Simulate exit after spawn
    vim.schedule(function()
      if exit_callback then
        exit_callback(0, 0)
      end
    end)
    
    vim.wait(100, function()
      return called.on_exit
    end)
    
    assert.is_true(called.on_exit)
    assert.is_nil(server.job)
    assert.is_nil(server.url)
    assert.is_nil(server.handle)
  end)
end)
