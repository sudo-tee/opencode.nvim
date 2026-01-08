local OpencodeServer = require('opencode.opencode_server')
local assert = require('luassert')

--- Helper to get lock file path (mirrors the module's internal function)
local function get_lock_file_path()
  local tmpdir = vim.fn.stdpath('cache')
  return vim.fs.joinpath(tmpdir --[[@as string]], 'opencode-server.lock')
end

--- Helper to write a lock file directly for testing
--- @param url string
--- @param clients number[]
--- @param server_pid number|nil
local function write_test_lock_file(url, clients, server_pid)
  local lock_path = get_lock_file_path()
  local f = io.open(lock_path, 'w')
  if f then
    local clients_str = table.concat(
      vim.tbl_map(function(pid)
        return tostring(pid)
      end, clients),
      ','
    )
    f:write(string.format('url=%s\nclients=%s\n', url, clients_str))
    if server_pid then
      f:write(string.format('server_pid=%d\n', server_pid))
    end
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
  local clients_str = content:match('clients=([^\n]*)')
  local server_pid_str = content:match('server_pid=([^\n]+)')
  local clients = {}
  if clients_str and clients_str ~= '' then
    for pid_str in clients_str:gmatch('([^,]+)') do
      local pid = tonumber(pid_str)
      if pid then
        table.insert(clients, pid)
      end
    end
  end
  local server_pid = tonumber(server_pid_str)
  return { url = url, clients = clients, server_pid = server_pid }
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
      write_test_lock_file('http://localhost:8888', { 99999 }, 99999)

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
      -- Use current_pid as the existing client so it's always "alive"
      write_test_lock_file('http://localhost:9999', { current_pid }, 54321)

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
      assert.is_true(vim.tbl_contains(lock_data.clients, current_pid))
      assert.equals(54321, lock_data.server_pid)
    end)

    it('spawn creates lock file with server_pid', function()
      local current_pid = vim.fn.getpid()

      vim.uv.kill = function(pid, sig)
        if sig == 0 then
          return 0
        end
      end

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
      assert.is_true(vim.tbl_contains(lock_data.clients, current_pid))
      assert.equals(current_pid, lock_data.server_pid)
    end)

    it('shutdown removes client from lock file', function()
      local current_pid = vim.fn.getpid()
      local other_pid = current_pid + 1000000 -- Use a fake but distinct PID
      write_test_lock_file('http://localhost:7777', { current_pid, other_pid }, 54321)

      -- Mock to make all PIDs appear alive
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
      assert.is_true(vim.tbl_contains(lock_data.clients, other_pid))
    end)

    it('shutdown removes lock file when last client exits', function()
      local current_pid = vim.fn.getpid()
      write_test_lock_file('http://localhost:6666', { current_pid }, 54321)

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

    it('shutdown keeps remaining clients when one client exits', function()
      local current_pid = vim.fn.getpid()
      local other_pid_1 = current_pid + 1000000 -- Use fake but distinct PIDs
      local other_pid_2 = current_pid + 2000000
      write_test_lock_file('http://localhost:4444', { current_pid, other_pid_1, other_pid_2 }, 54321)

      -- Mock to make all PIDs appear alive
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
      assert.equals(2, #lock_data.clients)
      assert.is_false(vim.tbl_contains(lock_data.clients, current_pid))
      assert.is_true(vim.tbl_contains(lock_data.clients, other_pid_1))
      assert.is_true(vim.tbl_contains(lock_data.clients, other_pid_2))
      assert.equals(54321, lock_data.server_pid)
    end)

    it('cleanup_dead_pids removes dead processes from clients list', function()
      local current_pid = vim.fn.getpid()
      local dead_pid = current_pid + 1000000 -- Use fake but distinct PIDs
      local alive_pid = current_pid + 2000000

      write_test_lock_file('http://localhost:3333', { dead_pid, alive_pid, current_pid }, 54321)

      -- Mock to make dead_pid appear dead, others alive
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
      assert.is_true(vim.tbl_contains(lock_data.clients, alive_pid))
      assert.is_true(vim.tbl_contains(lock_data.clients, current_pid))
      assert.equals(54321, lock_data.server_pid)
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
