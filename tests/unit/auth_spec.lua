local auth = require('opencode.auth')

describe('auth', function()
  it('converts a credential to Basic Auth', function()
    local headers = auth.get_auth_headers({ username = 'admin', password = 'secret' })
    assert.equals('Basic ' .. vim.base64.encode('admin:secret'), headers.Authorization)
  end)

  it('uses opencode as the default username', function()
    local headers = auth.get_auth_headers({ password = 'secret' })
    assert.equals('Basic ' .. vim.base64.encode('opencode:secret'), headers.Authorization)
  end)

  it('returns no header for a credential without a password', function()
    assert.same({}, auth.get_auth_headers({ username = 'opencode' }))
  end)

  it('converts a credential to both V1 and V2 spawn variables', function()
    assert.same({
      OPENCODE_PASSWORD = 'secret',
      OPENCODE_SERVER_PASSWORD = 'secret',
      OPENCODE_SERVER_USERNAME = 'admin',
    }, auth.get_env({ username = 'admin', password = 'secret' }))
  end)

  it('returns an empty environment for a credential without a password', function()
    assert.same({}, auth.get_env({ username = 'opencode' }))
  end)
end)
