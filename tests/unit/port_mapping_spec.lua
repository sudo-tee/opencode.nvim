local assert = require('luassert')
local OpencodeServer = require('opencode.opencode_server')

-- port_mapping writes/reads a JSON file via vim.fn.stdpath('data').
-- Redirect it to a temp path so tests are isolated.
local tmp_dir = vim.fn.tempname()
vim.fn.mkdir(tmp_dir, 'p')

local original_stdpath = vim.fn.stdpath
---@diagnostic disable-next-line: duplicate-set-field
vim.fn.stdpath = function(what)
  if what == 'data' then
    return tmp_dir
  end
  return original_stdpath(what)
end

local port_mapping = require('opencode.port_mapping')

local function mappings_file()
  return tmp_dir .. '/opencode_port_mappings.json'
end

local function write_mappings(t)
  local f = io.open(mappings_file(), 'w')
  assert(f)
  f:write(vim.json.encode(t))
  f:close()
end

local function read_mappings()
  local f = io.open(mappings_file(), 'r')
  if not f then
    return {}
  end
  local content = f:read('*all')
  f:close()
  local ok, data = pcall(vim.json.decode, content)
  return ok and data or {}
end

describe('port_mapping', function()
  local original_kill_pid
  local original_graceful_shutdown
  local original_getpid
  local original_uv_kill
  local kill_pid_calls
  local graceful_calls

  before_each(function()
    os.remove(mappings_file())

    kill_pid_calls = {}
    graceful_calls = {}

    original_kill_pid = OpencodeServer.kill_pid
    original_graceful_shutdown = OpencodeServer.request_graceful_shutdown
    original_getpid = vim.fn.getpid
    original_uv_kill = vim.uv.kill

    OpencodeServer.kill_pid = function(pid)
      table.insert(kill_pid_calls, pid)
    end
    OpencodeServer.request_graceful_shutdown = function(url)
      table.insert(graceful_calls, url)
    end
  end)

  after_each(function()
    OpencodeServer.kill_pid = original_kill_pid
    OpencodeServer.request_graceful_shutdown = original_graceful_shutdown
    vim.fn.getpid = original_getpid
    vim.uv.kill = original_uv_kill
    os.remove(mappings_file())
  end)

  -- Make a set of pids appear alive to vim.uv.kill signal-0 checks.
  -- Actual kill calls (signal != 0) are forwarded to the real impl.
  local function make_pids_alive(alive_set)
    vim.uv.kill = function(pid, signal)
      if signal == 0 then
        return alive_set[pid] and 0 or nil
      end
      return original_uv_kill(pid, signal)
    end
  end

  describe('register', function()
    it('creates a new mapping entry for a port', function()
      local real_pid = original_getpid()
      port_mapping.register(9000, '/my/project', true, 'serve', 'http://127.0.0.1:9000', 55)

      local m = read_mappings()
      assert.is_not_nil(m['9000'])
      assert.equals('/my/project', m['9000'].directory)
      assert.is_true(m['9000'].started_by_nvim)
      assert.equals('http://127.0.0.1:9000', m['9000'].url)
      assert.equals(55, m['9000'].server_pid)
      assert.equals(1, #m['9000'].nvim_pids)
      assert.equals(real_pid, m['9000'].nvim_pids[1].pid)
    end)

    it('does not duplicate the current pid when called twice', function()
      port_mapping.register(9001, '/proj', true)
      port_mapping.register(9001, '/proj', true)

      local m = read_mappings()
      assert.equals(1, #m['9001'].nvim_pids)
    end)

    it('adds a second pid from a different nvim instance', function()
      local real_pid = original_getpid()
      local fake_pid = 20202

      -- Pre-seed both pids as alive so clean_stale won't prune either
      make_pids_alive({ [real_pid] = true, [fake_pid] = true })

      -- Register the real nvim
      port_mapping.register(9002, '/proj', true)

      -- Register as if a second nvim instance (fake_pid) wrote its entry directly
      local m = read_mappings()
      table.insert(m['9002'].nvim_pids, { pid = fake_pid, directory = '/proj', mode = 'serve' })
      local f = io.open(mappings_file(), 'w')
      f:write(vim.json.encode(m))
      f:close()

      -- Re-register real nvim (should be idempotent and keep both pids alive)
      port_mapping.register(9002, '/proj', true)

      m = read_mappings()
      assert.equals(2, #m['9002'].nvim_pids)
    end)
  end)

  describe('find_port_for_directory', function()
    it('returns the port for a directory with a live pid', function()
      local real_pid = original_getpid()
      write_mappings({
        ['7000'] = {
          directory = '/some/dir',
          nvim_pids = { { pid = real_pid, directory = '/some/dir', mode = 'serve' } },
          started_by_nvim = true,
          auto_kill = true,
        },
      })

      local port = port_mapping.find_port_for_directory('/some/dir')
      assert.equals(7000, port)
    end)

    it('returns nil when no mapping exists for the directory', function()
      local port = port_mapping.find_port_for_directory('/nonexistent/dir')
      assert.is_nil(port)
    end)

    it('returns nil when the only pid is dead', function()
      write_mappings({
        ['7001'] = {
          directory = '/dead/dir',
          nvim_pids = { { pid = 999999, directory = '/dead/dir', mode = 'serve' } },
          started_by_nvim = true,
          auto_kill = true,
        },
      })

      local port = port_mapping.find_port_for_directory('/dead/dir')
      assert.is_nil(port)
    end)
  end)

  describe('mapped_directory', function()
    it('returns nil when port is not mapped', function()
      local dir = port_mapping.mapped_directory(8000, '/current/dir')
      assert.is_nil(dir)
    end)

    it('returns nil when port is mapped to current_dir', function()
      local real_pid = original_getpid()
      write_mappings({
        ['8001'] = {
          directory = '/current/dir',
          nvim_pids = { { pid = real_pid, directory = '/current/dir', mode = 'serve' } },
          started_by_nvim = true,
        },
      })

      local dir = port_mapping.mapped_directory(8001, '/current/dir')
      assert.is_nil(dir)
    end)

    it('returns the other directory when port is mapped to a different one', function()
      local real_pid = original_getpid()
      write_mappings({
        ['8002'] = {
          directory = '/other/dir',
          nvim_pids = { { pid = real_pid, directory = '/other/dir', mode = 'serve' } },
          started_by_nvim = true,
        },
      })

      local dir = port_mapping.mapped_directory(8002, '/current/dir')
      assert.equals('/other/dir', dir)
    end)
  end)

  describe('unregister', function()
    it('removes the current pid from the mapping', function()
      local real_pid = original_getpid()
      local fake_pid = 30303
      make_pids_alive({ [real_pid] = true, [fake_pid] = true })

      write_mappings({
        ['6000'] = {
          directory = '/proj',
          nvim_pids = {
            { pid = real_pid, directory = '/proj', mode = 'serve' },
            { pid = fake_pid, directory = '/proj', mode = 'serve' },
          },
          started_by_nvim = true,
          auto_kill = true,
          server_pid = 77,
        },
      })

      local fake_server = { mode = 'serve', job = nil, shutdown = function() end }
      port_mapping.unregister(6000, fake_server)

      local m = read_mappings()
      assert.is_not_nil(m['6000'])
      assert.equals(1, #m['6000'].nvim_pids)
      assert.equals(fake_pid, m['6000'].nvim_pids[1].pid)
    end)

    it('calls server:shutdown() when it is the last client and server has a job', function()
      local real_pid = original_getpid()
      write_mappings({
        ['6001'] = {
          directory = '/proj',
          nvim_pids = { { pid = real_pid, directory = '/proj', mode = 'serve' } },
          started_by_nvim = true,
          auto_kill = true,
          server_pid = 88,
        },
      })

      local shutdown_called = false
      local fake_server = {
        mode = 'serve',
        job = true,
        shutdown = function()
          shutdown_called = true
        end,
      }

      port_mapping.unregister(6001, fake_server)

      assert.is_true(shutdown_called)
      assert.equals(0, #kill_pid_calls)
    end)

    it('calls kill_pid and request_graceful_shutdown when last client and no job object', function()
      local real_pid = original_getpid()
      write_mappings({
        ['6002'] = {
          directory = '/proj',
          nvim_pids = { { pid = real_pid, directory = '/proj', mode = 'serve' } },
          started_by_nvim = true,
          auto_kill = true,
          server_pid = 99,
        },
      })

      local fake_server = { mode = 'serve', job = nil, shutdown = function() end }
      port_mapping.unregister(6002, fake_server)

      assert.equals(1, #kill_pid_calls)
      assert.equals(99, kill_pid_calls[1])
      assert.equals(1, #graceful_calls)
    end)

    it('does not shut down when other clients remain', function()
      local real_pid = original_getpid()
      local fake_pid = 40404
      make_pids_alive({ [real_pid] = true, [fake_pid] = true })

      write_mappings({
        ['6003'] = {
          directory = '/proj',
          nvim_pids = {
            { pid = real_pid, directory = '/proj', mode = 'serve' },
            { pid = fake_pid, directory = '/proj', mode = 'serve' },
          },
          started_by_nvim = true,
          auto_kill = true,
          server_pid = 55,
        },
      })

      local fake_server = { mode = 'serve', job = nil, shutdown = function() end }
      port_mapping.unregister(6003, fake_server)

      assert.equals(0, #kill_pid_calls)
      assert.equals(0, #graceful_calls)
    end)

    it('does nothing when port is nil', function()
      port_mapping.unregister(nil, nil)
      assert.equals(0, #kill_pid_calls)
    end)
  end)

  describe('clean_stale (via register/find)', function()
    it('kills orphaned server when all nvim pids are dead', function()
      write_mappings({
        ['5000'] = {
          directory = '/gone',
          nvim_pids = { { pid = 999998, directory = '/gone', mode = 'serve' } },
          started_by_nvim = true,
          auto_kill = true,
          server_pid = 44,
        },
      })

      port_mapping.find_port_for_directory('/gone')

      assert.equals(1, #kill_pid_calls)
      assert.equals(44, kill_pid_calls[1])
      assert.equals(1, #graceful_calls)
    end)

    it('does not kill server when started_by_nvim is false', function()
      write_mappings({
        ['5001'] = {
          directory = '/external',
          nvim_pids = { { pid = 999997, directory = '/external', mode = 'serve' } },
          started_by_nvim = false,
          auto_kill = false,
          server_pid = 45,
        },
      })

      port_mapping.find_port_for_directory('/external')

      assert.equals(0, #kill_pid_calls)
      assert.equals(0, #graceful_calls)
    end)
  end)
end)
