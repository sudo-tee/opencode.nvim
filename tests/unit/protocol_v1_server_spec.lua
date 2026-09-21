local config = require('opencode.config')
local server = require('opencode.protocols.v1.server')

describe('V1 server launcher', function()
  local executable
  local port
  local password_file

  before_each(function()
    executable = config.values.opencode_executable
    port = config.values.server.port
    password_file = config.values.server.password_file
    config.values.opencode_executable = 'opencode-v1'
  end)

  after_each(function()
    config.values.opencode_executable = executable
    config.values.server.port = port
    config.values.server.password_file = password_file
  end)

  it('owns the legacy serve command and normalizes its hostname', function()
    assert.same(
      { 'opencode-v1', 'serve', '--port', '4321', '--hostname', '127.0.0.1:4321' },
      server.command(4321, 'http://127.0.0.1:4321/path')
    )
  end)

  it('exposes only an explicitly configured port for reuse', function()
    config.values.server.port = 4321
    assert.equals(4321, server.configured_port())
    assert.equals('http://127.0.0.1:4321', server.endpoint(4321))

    config.values.server.port = 'auto'
    assert.is_nil(server.configured_port())
  end)

  it('uses a stable per-port credential file unless one is configured', function()
    config.values.server.password_file = nil
    assert.matches('/opencode/v1%-4321%.password$', server.credential_file(4321))

    config.values.server.password_file = '/configured/password'
    assert.equals('/configured/password', server.credential_file(4321))
  end)

  it('recognizes the legacy launcher readiness message', function()
    assert.equals(
      'http://127.0.0.1:4321',
      server.listening_url('opencode server listening on http://127.0.0.1:4321')
    )
    assert.is_nil(server.listening_url('starting'))
  end)
end)
