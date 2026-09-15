local Promise = require('opencode.promise')
local config = require('opencode.config')
local state = require('opencode.state')
local curl = require('opencode.curl')
local mapping = require('opencode.port_mapping')
local server_job = require('opencode.server_job')
local assert = require('luassert')

describe('native V2 service discovery', function()
  local saved, commands, replies, status, request_headers
  before_each(function()
    saved = {
      system = Promise.system,
      request = curl.request,
      register = mapping.register,
      server = state.opencode_server,
      config = config.values.server,
      spawn = server_job.spawn_local_server,
    }
    state.jobs.clear_server()
    config.values.server = { timeout = 1, auto_kill = true, password = 'wrong-explicit-password' }
    commands = {}
    replies = {
      ['--help'] = 'SUBCOMMANDS\n  service   Manage the background server',
      ['service status'] = 'http://127.0.0.1:49374',
      ['service get password'] = 'native-password',
      ['service start'] = 'http://127.0.0.1:49374',
    }
    status = 200
    Promise.system = function(args)
      local command = table.concat(args, ' ', 2)
      commands[#commands + 1] = command
      assert.is_not_nil(replies[command])
      return Promise.new():resolve({ code = 0, stdout = replies[command] .. '\n' })
    end
    curl.request = function(opts)
      assert.equals('http://127.0.0.1:49374/api/health', opts.url)
      request_headers = opts.headers
      vim.schedule(function()
        opts.callback({ status = status, body = '{"healthy":true,"version":"2.0.3","pid":123}' })
      end)
    end
    mapping.register = function()
      error('native service must not enter port mapping')
    end
    server_job.spawn_local_server = function()
      error('must not spawn private server')
    end
  end)
  after_each(function()
    Promise.system, curl.request, mapping.register = saved.system, saved.request, saved.register
    server_job.spawn_local_server = saved.spawn
    config.values.server = saved.config
    state.jobs.set_server(saved.server)
  end)

  it('uses native endpoint and credential without acquiring process release', function()
    local server = server_job.ensure_server():wait()
    assert.equals('v2', server.protocol)
    assert.is_nil(server.port)
    assert.equals('native-password', server.credential.password)
    assert.same({ version = '2.0.3', pid = 123 }, server.server_identity)
    assert.is_false(server:can_release_process())
    assert.same(require('opencode.auth').get_auth_headers(server.credential), request_headers)
    assert.is_true(server:close():wait())
    assert.same({ '--help', 'service status', 'service get password' }, commands)
  end)

  it('checkhealth clears and closes the Connection it acquired without killing the native service', function()
    local health_api = vim.health or require('health')
    local original = {
      executable = vim.fn.executable,
      system = vim.system,
      kill_pid = require('opencode.opencode_server').kill_pid,
      start = health_api.start,
      ok = health_api.ok,
      error = health_api.error,
      warn = health_api.warn,
      info = health_api.info,
    }
    local messages, acquired, killed = {}, nil, false
    for _, name in ipairs({ 'start', 'ok', 'error', 'warn', 'info' }) do
      health_api[name] = function(message)
        messages[#messages + 1] = message
      end
    end
    vim.fn.executable = function()
      return 1
    end
    vim.system = function()
      return {
        wait = function()
          return { code = 0, stdout = 'opencode v2.0.3\n' }
        end,
      }
    end
    require('opencode.opencode_server').kill_pid = function()
      killed = true
    end
    curl.request = function(opts)
      vim.schedule(function()
        if opts.url:match('/api/health$') then
          opts.callback({ status = 200, body = '{"healthy":true,"version":"2.0.1","pid":123}' })
        else
          acquired = state.opencode_server
          assert.matches('^http://127%.0%.0%.1:49374/api/config%?', opts.url)
          opts.callback({ status = 200, body = '{}' })
        end
      end)
      return {
        is_running = function()
          return true
        end,
        shutdown = function() end,
      }
    end

    local ok, err = pcall(require('opencode.health').check)

    vim.fn.executable = original.executable
    vim.system = original.system
    require('opencode.opencode_server').kill_pid = original.kill_pid
    for _, name in ipairs({ 'start', 'ok', 'error', 'warn', 'info' }) do
      health_api[name] = original[name]
    end

    assert.is_true(ok, err)
    assert.is_nil(state.opencode_server)
    assert.is_not_nil(acquired)
    assert.is_false(acquired:is_ready())
    assert.is_false(killed)
    assert.is_true(vim.tbl_contains(messages, 'opencode v2 server 2.0.1 is reachable at http://127.0.0.1:49374'))
    assert.is_true(vim.tbl_contains(messages, 'this Connection closes client resources only; the native service remains running'))
    assert.is_true(vim.tbl_contains(messages, 'opencode connection closed successfully'))
  end)

  it('delegates startup only when the native CLI reports stopped', function()
    replies['service status'] = 'stopped'
    assert.equals('v2', server_job.ensure_server():wait().protocol)
    assert.same({ '--help', 'service status', 'service start', 'service get password' }, commands)
  end)

  it('does not launch or downgrade after rejected native credentials', function()
    status = 401
    assert.is_false(pcall(function()
      server_job.ensure_server():wait()
    end))
    assert.is_nil(state.opencode_server)
    assert.same({ '--help', 'service status', 'service get password' }, commands)
  end)

  it('rejects a malformed status before fetching a password or publishing', function()
    replies['service status'] = 'unexpected output'
    assert.is_false(pcall(function()
      server_job.ensure_server():wait()
    end))
    assert.same({ '--help', 'service status' }, commands)
    assert.is_nil(state.opencode_server)
  end)

  it('keeps V1 startup when the CLI has no service command', function()
    replies['--help'] = 'Commands:\n  opencode serve  starts a headless server'
    local legacy = {}
    server_job.spawn_local_server = function(promise)
      promise:resolve(legacy)
    end
    assert.equals(legacy, server_job.ensure_server():wait())
    assert.same({ '--help' }, commands)
  end)
end)
