local OpencodeServer = require('opencode.opencode_server')
local assert = require('luassert')

--- Helper to get lock file path (mirrors the module's internal function)
local function get_lock_file_path()
  local tmpdir = vim.fn.stdpath('cache')
  return vim.fs.joinpath(tmpdir --[[@as string]], 'opencode-server.lock')
end

--- Helper to write a lock file directly for testing
local function write_test_lock_file(url, owner, clients)
  local lock_path = get_lock_file_path()
  local f = io.open(lock_path, 'w')
  if f then
    local clients_str = table.concat(
      vim.tbl_map(function(pid)
        return tostring(pid)
      end, clients),
      ','
    )
    f:write(string.format('url=%s\nowner=%d\nclients=%s\n', url, owner, clients_str))
    f:close()
  end
end

--- Helper to read lock file directly for testing
local function read_test_lock_file()
  local lock_path = get_lock_file_path()
  local f = io.open(lock_path, 'r')
  if not f then
    return nil
  end
  local content = f:read('*a')
  f:close()
  if not content or content == '' then
    return nil
  end
  local url = content:match('url=([^\n]+)')
  local owner_str = content:match('owner=([^\n]+)')
  local clients_str = content:match('clients=([^\n]*)')
  local owner = tonumber(owner_str) or 0
  local clients = {}
  if clients_str and clients_str ~= '' then
    for pid_str in clients_str:gmatch('([^,]+)') do
      local pid = tonumber(pid_str)
      if pid then
        table.insert(clients, pid)
      end
    end
  end
  return { url = url, owner = owner, clients = clients }
end

local function remove_test_lock_file()
  local lock_path = get_lock_file_path()
  os.remove(lock_path)
  os.remove(lock_path .. '.flock')
end

describe('opencode.opencode_server', function()
  local original_system
  local original_uv_kill
  before_each(function()
    original_system = vim.system
    original_uv_kill = vim.uv.kill
    remove_test_lock_file()
  end)
  after_each(function()
    vim.system = original_system
    vim.uv.kill = original_uv_kill
    remove_test_lock_file()
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
    server.job = { pid = 2, kill = function() end }
    server.url = 'http://x'
    server.handle = 2
    local resolved = false
    server:get_shutdown_promise():and_then(function()
      resolved = true
    end)
    server:shutdown()
    vim.wait(50, function()
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

  describe('lock file operations', function()
    it('try_existing_server returns nil when no lock file exists', function()
      local url = OpencodeServer.try_existing_server()
      assert.is_nil(url)
    end)

    it('try_existing_server returns nil when lock file has no alive clients', function()
      write_test_lock_file('http://localhost:8888', 99999, { 99999 })

      vim.uv.kill = function(pid, sig)
        if sig == 0 then
          error('ESRCH: no such process')
        end
      end

      local url = OpencodeServer.try_existing_server()
      assert.is_nil(url)

      local lock_data = read_test_lock_file()
      assert.is_nil(lock_data)
    end)

    it('from_existing creates server with url and registers as client', function()
      local current_pid = vim.fn.getpid()
      write_test_lock_file('http://localhost:9999', 12345, { 12345 })

      vim.uv.kill = function(pid, sig)
        if sig == 0 then
          return 0
        end
      end

      local server = OpencodeServer.from_existing('http://localhost:9999')

      assert.equals('http://localhost:9999', server.url)
      assert.is_false(server.is_owner)

      local lock_data = read_test_lock_file()
      assert.is_not_nil(lock_data)
      assert.equals(12345, lock_data.owner)
      assert.is_true(vim.tbl_contains(lock_data.clients, current_pid))
    end)

    it('spawn registers as owner in lock file', function()
      local current_pid = vim.fn.getpid()

      vim.system = function(cmd, opts)
        vim.schedule(function()
          opts.stdout(nil, 'opencode server listening on http://127.0.0.1:5555')
        end)
        return { pid = current_pid, kill = function() end }
      end

      local server = OpencodeServer.new()
      local resolved = false

      server:spawn({
        cwd = '.',
        on_ready = function()
          resolved = true
        end,
        on_error = function() end,
        on_exit = function() end,
      })

      vim.wait(100, function()
        return resolved
      end)

      assert.is_true(server.is_owner)

      local lock_data = read_test_lock_file()
      assert.is_not_nil(lock_data)
      assert.equals('http://127.0.0.1:5555', lock_data.url)
      assert.equals(current_pid, lock_data.owner)
      assert.is_true(vim.tbl_contains(lock_data.clients, current_pid))
    end)

    it('shutdown removes client from lock file', function()
      local current_pid = vim.fn.getpid()
      write_test_lock_file('http://localhost:7777', current_pid, { current_pid, 99998 })

      vim.uv.kill = function(pid, sig)
        if sig == 0 then
          return 0
        end
      end

      local server = OpencodeServer.new()
      server.url = 'http://localhost:7777'
      server.is_owner = true
      server.job = { pid = current_pid, kill = function() end }

      server:shutdown()

      local lock_data = read_test_lock_file()
      assert.is_not_nil(lock_data)
      assert.is_false(vim.tbl_contains(lock_data.clients, current_pid))
      assert.equals(99998, lock_data.owner)
    end)

    it('shutdown removes lock file when last client exits', function()
      local current_pid = vim.fn.getpid()
      write_test_lock_file('http://localhost:6666', current_pid, { current_pid })

      vim.uv.kill = function(pid, sig)
        if sig == 0 then
          return 0
        end
      end

      local server = OpencodeServer.new()
      server.url = 'http://localhost:6666'
      server.is_owner = true
      server.job = { pid = current_pid, kill = function() end }

      server:shutdown()

      local lock_data = read_test_lock_file()
      assert.is_nil(lock_data)
    end)

    it('ownership transfers to next client when owner exits', function()
      local current_pid = vim.fn.getpid()
      local other_pid_1 = 88881
      local other_pid_2 = 88882
      write_test_lock_file('http://localhost:4444', current_pid, { current_pid, other_pid_1, other_pid_2 })

      vim.uv.kill = function(pid, sig)
        if sig == 0 then
          return 0
        end
      end

      local server = OpencodeServer.new()
      server.url = 'http://localhost:4444'
      server.is_owner = true
      server.job = { pid = current_pid, kill = function() end }

      server:shutdown()

      local lock_data = read_test_lock_file()
      assert.is_not_nil(lock_data)
      assert.equals(other_pid_1, lock_data.owner)
      assert.equals(2, #lock_data.clients)
      assert.is_false(vim.tbl_contains(lock_data.clients, current_pid))
      assert.is_true(vim.tbl_contains(lock_data.clients, other_pid_1))
      assert.is_true(vim.tbl_contains(lock_data.clients, other_pid_2))
    end)

    it('cleanup_dead_pids removes dead processes and promotes new owner', function()
      local current_pid = vim.fn.getpid()
      local dead_pid = 99997
      local alive_pid = 99996

      write_test_lock_file('http://localhost:3333', dead_pid, { dead_pid, alive_pid, current_pid })

      vim.uv.kill = function(pid, sig)
        if sig == 0 then
          if pid == dead_pid then
            error('ESRCH: no such process')
          end
          return 0
        end
      end

      local server = OpencodeServer.from_existing('http://localhost:3333')

      local lock_data = read_test_lock_file()
      assert.is_not_nil(lock_data)
      assert.is_false(vim.tbl_contains(lock_data.clients, dead_pid))
      assert.equals(alive_pid, lock_data.owner)
    end)

    it('flock file is created and removed during operations', function()
      local flock_path = get_lock_file_path() .. '.flock'

      vim.uv.kill = function(pid, sig)
        if sig == 0 then
          return 0
        end
      end

      vim.system = function(cmd, opts)
        vim.schedule(function()
          opts.stdout(nil, 'opencode server listening on http://127.0.0.1:1111')
        end)
        return { pid = vim.fn.getpid(), kill = function() end }
      end

      local server = OpencodeServer.new()
      local resolved = false

      server:spawn({
        cwd = '.',
        on_ready = function()
          resolved = true
        end,
        on_error = function() end,
        on_exit = function() end,
      })

      vim.wait(100, function()
        return resolved
      end)

      local flock_exists_after = vim.uv.fs_stat(flock_path) ~= nil
      assert.is_false(flock_exists_after)
    end)
  end)
end)
