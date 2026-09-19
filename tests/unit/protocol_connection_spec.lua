local assert = require('luassert')
local curl = require('opencode.curl')
local config = require('opencode.config')
local state = require('opencode.state')
local server_job = require('opencode.server_job')
local mapping = require('opencode.port_mapping')

describe('authenticated connection boundary', function()
  local saved, requests, spawns, registrations, password_path

  before_each(function()
    saved = {
      request = curl.request,
      server_config = vim.deepcopy(config.values.server),
      connection = state.opencode_server,
      register = mapping.register,
      password = vim.env.OPENCODE_PASSWORD,
      legacy_password = vim.env.OPENCODE_SERVER_PASSWORD,
      username = vim.env.OPENCODE_SERVER_USERNAME,
    }
    state.jobs.clear_server()
    config.values.server.url = '127.0.0.1'
    config.values.server.port = 4798
    config.values.server.auto_kill = false
    config.values.server.password = 'connection-test'
    config.values.server.retry_delay = 1
    requests, spawns, registrations = {}, 0, 0
    config.values.server.spawn_command = function()
      spawns = spawns + 1
    end
    mapping.register = function()
      registrations = registrations + 1
    end
  end)

  after_each(function()
    curl.request = saved.request
    config.values.server = saved.server_config
    mapping.register = saved.register
    state.jobs.set_server(saved.connection)
    vim.env.OPENCODE_PASSWORD = saved.password
    vim.env.OPENCODE_SERVER_PASSWORD = saved.legacy_password
    vim.env.OPENCODE_SERVER_USERNAME = saved.username
    if password_path then
      os.remove(password_path)
    end
  end)

  for _, response in ipairs({
    { status = 200, body = '<!doctype html><title>OpenCode</title>' },
    { status = 200, body = '{invalid json' },
    { status = 401, body = 'Unauthorized' },
    { status = 403, body = 'Forbidden' },
  }) do
    it('rejects HTTP ' .. response.status .. ' ' .. response.body .. ' without publishing or spawning', function()
      curl.request = function(opts)
        requests[#requests + 1] = opts.url
        vim.schedule(function()
          opts.callback(response)
        end)
      end
      local ok = pcall(function()
        server_job.ensure_server():wait()
      end)
      assert.is_false(ok)
      assert.same({ 'http://127.0.0.1:4798/api/info' }, requests)
      assert.equals(0, spawns)
      assert.equals(0, registrations)
      assert.is_nil(state.opencode_server)
    end)
  end

  it('probes V1 after the V2 health endpoint returns 404', function()
    curl.request = function(opts)
      requests[#requests + 1] = opts.url
      vim.schedule(function()
        opts.callback(
          opts.url:match('/api/info$') and { status = 404, body = '{}' }
            or { status = 200, body = '{"healthy":true,"version":"1.18.30"}' }
        )
      end)
    end
    local connection = server_job.ensure_server():wait()
    assert.same({ 'http://127.0.0.1:4798/api/info', 'http://127.0.0.1:4798/global/health' }, requests)
    assert.equals('v1', connection.protocol)
    assert.equals('1.18.30', connection.version)
    assert.equals(connection, state.opencode_server)
    assert.equals(0, spawns)
  end)

  it('falls back to V1 when the V2 endpoint carries no version', function()
    curl.request = function(opts)
      requests[#requests + 1] = opts.url
      vim.schedule(function()
        opts.callback(
          opts.url:match('/api/info$') and { status = 200, body = '{"healthy":true}' }
            or { status = 200, body = '{"healthy":true,"version":"1.18.30-a53585ffc0"}' }
        )
      end)
    end

    local connection = server_job.ensure_server():wait()

    assert.same({ 'http://127.0.0.1:4798/api/info', 'http://127.0.0.1:4798/global/health' }, requests)
    assert.equals('v1', connection.protocol)
    assert.equals('1.18.30-a53585ffc0', connection.version)
    assert.equals(connection, state.opencode_server)
    assert.equals(0, spawns)
  end)

  it('rejects when neither endpoint yields a version', function()
    curl.request = function(opts)
      requests[#requests + 1] = opts.url
      vim.schedule(function()
        opts.callback({ status = 200, body = '{"healthy":true,"pid":123}' })
      end)
    end

    local ok, err = pcall(function()
      server_job.ensure_server():wait()
    end)

    assert.is_false(ok)
    assert.matches('invalid health response', tostring(err))
    assert.same({ 'http://127.0.0.1:4798/api/info', 'http://127.0.0.1:4798/global/health' }, requests)
  end)

  it('selects password_file before both password environment variables', function()
    password_path = vim.fn.tempname()
    vim.fn.writefile({ 'file-secret' }, password_path)
    assert.equals(1, vim.fn.setfperm(password_path, 'rw-------'))
    config.values.server.password = nil
    config.values.server.password_file = password_path
    vim.env.OPENCODE_PASSWORD = 'v2-env-secret'
    vim.env.OPENCODE_SERVER_PASSWORD = 'v1-env-secret'
    local authorization
    curl.request = function(opts)
      authorization = opts.headers.Authorization
      vim.schedule(function()
        opts.callback({ status = 200, body = '{"healthy":true,"version":"2.0.1"}' })
      end)
    end

    local connection = server_job.ensure_server():wait()

    assert.equals('file-secret', connection.credential.password)
    assert.equals('Basic ' .. vim.base64.encode('opencode:file-secret'), authorization)
  end)

  it('fails before HTTP when a configured credential function throws', function()
    config.values.server.password = function()
      error('credential callback failed')
    end
    curl.request = function()
      requests[#requests + 1] = 'unexpected'
    end

    local ok, err = pcall(function()
      server_job.ensure_server():wait()
    end)

    assert.is_false(ok)
    assert.matches('credential callback failed', tostring(err))
    assert.same({}, requests)
  end)

  it('rejects an insecure password_file instead of falling through to env', function()
    password_path = vim.fn.tempname()
    vim.fn.writefile({ 'file-secret' }, password_path)
    assert.equals(1, vim.fn.setfperm(password_path, 'rw-r--r--'))
    config.values.server.password = nil
    config.values.server.password_file = password_path
    vim.env.OPENCODE_PASSWORD = 'env-secret'
    curl.request = function()
      requests[#requests + 1] = 'unexpected'
    end

    local ok, err = pcall(function()
      server_job.ensure_server():wait()
    end)

    assert.is_false(ok)
    assert.matches('accessible only by its owner', tostring(err))
    assert.same({}, requests)
  end)

  it('falls back to V1 and rejects when neither endpoint yields a version', function()
    curl.request = function(opts)
      requests[#requests + 1] = opts.url
      vim.schedule(function()
        opts.callback({ status = 200, body = '{"healthy":"true"}' })
      end)
    end

    local ok, err = pcall(function()
      server_job.ensure_server():wait()
    end)

    assert.is_false(ok)
    assert.matches('invalid health response', tostring(err))
    assert.same({ 'http://127.0.0.1:4798/api/info', 'http://127.0.0.1:4798/global/health' }, requests)
    assert.equals(0, spawns)
    assert.equals(0, registrations)
    assert.is_nil(state.opencode_server)
  end)

  it('rejects a malformed HTTP status without leaving the probe pending', function()
    curl.request = function(opts)
      requests[#requests + 1] = opts.url
      vim.schedule(function()
        opts.callback({ status = '200', body = '{"healthy":true,"version":"2.0.1"}' })
      end)
    end

    local ok, err = pcall(function()
      server_job.ensure_server():wait()
    end)

    assert.is_false(ok)
    assert.matches('invalid health response', tostring(err))
    assert.same({ 'http://127.0.0.1:4798/api/info' }, requests)
    assert.is_nil(state.opencode_server)
  end)

  it('rejects a V1 sentinel when global health is HTML', function()
    curl.request = function(opts)
      requests[#requests + 1] = opts.url
      vim.schedule(function()
        opts.callback(
          opts.url:match('/api/info$') and { status = 200, body = '{"healthy":true}' }
            or { status = 200, body = '<!doctype html><title>OpenCode</title>' }
        )
      end)
    end

    local ok, err = pcall(function()
      server_job.ensure_server():wait()
    end)

    assert.is_false(ok)
    assert.matches('invalid health response', tostring(err))
    assert.same({ 'http://127.0.0.1:4798/api/info', 'http://127.0.0.1:4798/global/health' }, requests)
    assert.equals(0, spawns)
    assert.equals(0, registrations)
    assert.is_nil(state.opencode_server)
  end)

  it('accepts V2 versions across the 2.x series', function()
    curl.request = function(opts)
      requests[#requests + 1] = opts.url
      vim.schedule(function()
        opts.callback({ status = 200, body = '{"version":"2.1.0","pid":1}' })
      end)
    end

    local connection = server_job.ensure_server():wait()

    assert.equals('v2', connection.protocol)
    assert.equals('2.1.0', connection.version)
    assert.same({ 'http://127.0.0.1:4798/api/info' }, requests)
    assert.equals(0, spawns)
  end)

  it('rejects V2 versions outside 2.x without spawning or publishing', function()
    curl.request = function(opts)
      requests[#requests + 1] = opts.url
      vim.schedule(function()
        opts.callback({ status = 200, body = '{"version":"3.0.0","pid":1}' })
      end)
    end

    local ok, err = pcall(function()
      server_job.ensure_server():wait()
    end)

    assert.is_false(ok)
    assert.matches('unsupported v2 server version: 3.0.0', tostring(err))
    assert.equals(0, spawns)
    assert.equals(0, registrations)
    assert.is_nil(state.opencode_server)
  end)

  it('rejects V1 versions outside 1.18.x after the permitted fallback probe', function()
    curl.request = function(opts)
      requests[#requests + 1] = opts.url
      vim.schedule(function()
        opts.callback(
          opts.url:match('/api/info$') and { status = 404, body = '{}' }
            or { status = 200, body = '{"healthy":true,"version":"1.19.0"}' }
        )
      end)
    end

    local ok, err = pcall(function()
      server_job.ensure_server():wait()
    end)

    assert.is_false(ok)
    assert.matches('unsupported v1 server version: 1.19.0', tostring(err))
    assert.equals(0, spawns)
    assert.equals(0, registrations)
    assert.is_nil(state.opencode_server)
  end)

  it('surfaces a health 5xx response without invoking the launcher', function()
    curl.request = function(opts)
      requests[#requests + 1] = opts.url
      vim.schedule(function()
        opts.callback({ status = 503, body = '{}' })
      end)
    end

    local ok, err = pcall(function()
      server_job.ensure_server():wait()
    end)

    assert.is_false(ok)
    assert.matches('health probe HTTP 503', tostring(err))
    assert.equals(0, spawns)
    assert.equals(0, registrations)
    assert.is_nil(state.opencode_server)
  end)
end)
