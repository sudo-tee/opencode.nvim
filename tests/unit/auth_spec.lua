local auth = require('opencode.auth')
local config = require('opencode.config')

describe('auth', function()
  local original_config
  local original_env_password
  local original_env_username

  before_each(function()
    auth.clear_cache()
    original_config = vim.deepcopy(config.values)
    original_env_password = vim.env.OPENCODE_SERVER_PASSWORD
    original_env_username = vim.env.OPENCODE_SERVER_USERNAME
    config.values.server.password = nil
    config.values.server.username = nil
    vim.env.OPENCODE_SERVER_PASSWORD = nil
    vim.env.OPENCODE_SERVER_USERNAME = nil
  end)

  after_each(function()
    config.values = original_config
    if original_env_password then
      vim.env.OPENCODE_SERVER_PASSWORD = original_env_password
    else
      vim.env.OPENCODE_SERVER_PASSWORD = nil
    end
    if original_env_username then
      vim.env.OPENCODE_SERVER_USERNAME = original_env_username
    else
      vim.env.OPENCODE_SERVER_USERNAME = nil
    end
  end)

  it('returns empty table when no password is configured', function()
    local headers = auth.get_auth_headers()
    assert.same({}, headers)
  end)

  it('returns empty table when password is empty string', function()
    config.values.server.password = ''
    local headers = auth.get_auth_headers()
    assert.same({}, headers)
  end)

  it('returns Basic auth header when password is in config', function()
    config.values.server.password = 'secret'
    local headers = auth.get_auth_headers()
    assert.equals('Basic ' .. vim.base64.encode('opencode:secret'), headers['Authorization'])
  end)

  it('uses configured username from config', function()
    config.values.server.username = 'admin'
    config.values.server.password = 'password123'
    local headers = auth.get_auth_headers()
    assert.equals('Basic ' .. vim.base64.encode('admin:password123'), headers['Authorization'])
  end)

  it('defaults username to "opencode" when not configured', function()
    config.values.server.password = 'secret'
    local headers = auth.get_auth_headers()
    assert.equals('Basic ' .. vim.base64.encode('opencode:secret'), headers['Authorization'])
  end)

  it('falls back to OPENCODE_SERVER_PASSWORD env var', function()
    vim.env.OPENCODE_SERVER_PASSWORD = 'envpass'
    local headers = auth.get_auth_headers()
    assert.equals('Basic ' .. vim.base64.encode('opencode:envpass'), headers['Authorization'])
  end)

  it('falls back to OPENCODE_SERVER_USERNAME env var', function()
    config.values.server.password = 'secret'
    vim.env.OPENCODE_SERVER_USERNAME = 'envuser'
    local headers = auth.get_auth_headers()
    local decoded = vim.base64.decode(headers['Authorization']:match('Basic (.+)'))
    assert.equals('envuser:secret', decoded)
  end)

  it('config values take precedence over env vars', function()
    config.values.server.username = 'cfguser'
    config.values.server.password = 'cfgpass'
    vim.env.OPENCODE_SERVER_USERNAME = 'envuser'
    vim.env.OPENCODE_SERVER_PASSWORD = 'envpass'
    local headers = auth.get_auth_headers()
    local decoded = vim.base64.decode(headers['Authorization']:match('Basic (.+)'))
    assert.equals('cfguser:cfgpass', decoded)
  end)

  it('defaults username to "opencode" when only env password is set', function()
    vim.env.OPENCODE_SERVER_PASSWORD = 'envpass'
    local headers = auth.get_auth_headers()
    local decoded = vim.base64.decode(headers['Authorization']:match('Basic (.+)'))
    assert.equals('opencode:envpass', decoded)
  end)

  describe('function values', function()
    it('resolves password from a function', function()
      config.values.server.password = function()
        return 'funcpass'
      end
      local headers = auth.get_auth_headers()
      assert.equals('Basic ' .. vim.base64.encode('opencode:funcpass'), headers['Authorization'])
    end)

    it('resolves username from a function', function()
      config.values.server.password = 'secret'
      config.values.server.username = function()
        return 'funcuser'
      end
      local headers = auth.get_auth_headers()
      assert.equals('Basic ' .. vim.base64.encode('funcuser:secret'), headers['Authorization'])
    end)

    it('function returning nil falls through to env var', function()
      config.values.server.password = function()
        return nil
      end
      vim.env.OPENCODE_SERVER_PASSWORD = 'envpass'
      local headers = auth.get_auth_headers()
      assert.equals('Basic ' .. vim.base64.encode('opencode:envpass'), headers['Authorization'])
    end)

    it('function returning empty string falls through to env var', function()
      config.values.server.password = function()
        return ''
      end
      vim.env.OPENCODE_SERVER_PASSWORD = 'envpass'
      local headers = auth.get_auth_headers()
      assert.equals('Basic ' .. vim.base64.encode('opencode:envpass'), headers['Authorization'])
    end)

    it('function that errors falls through to env var', function()
      config.values.server.password = function()
        error('file not found')
      end
      vim.env.OPENCODE_SERVER_PASSWORD = 'envpass'
      local headers = auth.get_auth_headers()
      assert.equals('Basic ' .. vim.base64.encode('opencode:envpass'), headers['Authorization'])
    end)

    it('function username nil falls through to env var', function()
      config.values.server.password = 'secret'
      config.values.server.username = function()
        return nil
      end
      vim.env.OPENCODE_SERVER_USERNAME = 'envuser'
      local headers = auth.get_auth_headers()
      local decoded = vim.base64.decode(headers['Authorization']:match('Basic (.+)'))
      assert.equals('envuser:secret', decoded)
    end)
  end)

  describe('caching', function()
    it('caches resolved credentials across calls', function()
      config.values.server.password = 'secret'
      config.values.server.username = 'admin'
      local headers1 = auth.get_auth_headers()
      local headers2 = auth.get_auth_headers()
      assert.same(headers1, headers2)
    end)

    it('does not re-evaluate config after cache is populated', function()
      local call_count = 0
      config.values.server.password = function()
        call_count = call_count + 1
        return 'pass' .. tostring(call_count)
      end

      local h1 = auth.get_auth_headers()
      local h2 = auth.get_auth_headers()
      assert.equals(1, call_count)
      assert.same(h1, h2)
    end)

    it('clear_cache resets and re-resolves', function()
      config.values.server.password = 'first'
      auth.get_auth_headers()

      config.values.server.password = 'second'
      auth.clear_cache()
      local headers = auth.get_auth_headers()
      assert.equals('Basic ' .. vim.base64.encode('opencode:second'), headers['Authorization'])
    end)
  end)

  describe('get_env', function()
    it('returns empty table when no password is configured', function()
      local env = auth.get_env()
      assert.same({}, env)
    end)

    it('returns empty table when password is empty string', function()
      config.values.server.password = ''
      local env = auth.get_env()
      assert.same({}, env)
    end)

    it('returns env vars when password is in config', function()
      config.values.server.password = 'secret'
      config.values.server.username = 'admin'
      local env = auth.get_env()
      assert.equals('secret', env.OPENCODE_SERVER_PASSWORD)
      assert.equals('admin', env.OPENCODE_SERVER_USERNAME)
    end)

    it('defaults username to "opencode" when not configured', function()
      config.values.server.password = 'secret'
      local env = auth.get_env()
      assert.equals('secret', env.OPENCODE_SERVER_PASSWORD)
      assert.equals('opencode', env.OPENCODE_SERVER_USERNAME)
    end)

    it('falls back to OPENCODE_SERVER_PASSWORD env var', function()
      vim.env.OPENCODE_SERVER_PASSWORD = 'envpass'
      local env = auth.get_env()
      assert.equals('envpass', env.OPENCODE_SERVER_PASSWORD)
    end)

    it('falls back to OPENCODE_SERVER_USERNAME env var', function()
      config.values.server.password = 'secret'
      vim.env.OPENCODE_SERVER_USERNAME = 'envuser'
      local env = auth.get_env()
      assert.equals('envuser', env.OPENCODE_SERVER_USERNAME)
    end)

    it('config values take precedence over env vars', function()
      config.values.server.username = 'cfguser'
      config.values.server.password = 'cfgpass'
      vim.env.OPENCODE_SERVER_USERNAME = 'envuser'
      vim.env.OPENCODE_SERVER_PASSWORD = 'envpass'
      local env = auth.get_env()
      assert.equals('cfgpass', env.OPENCODE_SERVER_PASSWORD)
      assert.equals('cfguser', env.OPENCODE_SERVER_USERNAME)
    end)

    it('resolves password from a function', function()
      config.values.server.password = function()
        return 'funcpass'
      end
      local env = auth.get_env()
      assert.equals('funcpass', env.OPENCODE_SERVER_PASSWORD)
    end)

    it('resolves username from a function', function()
      config.values.server.password = 'secret'
      config.values.server.username = function()
        return 'funcuser'
      end
      local env = auth.get_env()
      assert.equals('funcuser', env.OPENCODE_SERVER_USERNAME)
    end)
  end)
end)
