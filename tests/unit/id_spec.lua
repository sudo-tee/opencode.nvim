local id = require('opencode.id')

describe('ID module', function()
  it('should generate ascending session IDs', function()
    local id1 = id.ascending('session')
    local id2 = id.ascending('session')

    assert.is_string(id1)
    assert.is_string(id2)
    assert.is_true(vim.startswith(id1, 'ses_'))
    assert.is_true(vim.startswith(id2, 'ses_'))
    assert.is_not.equal(id1, id2)
  end)

  it('should generate descending message IDs', function()
    local id1 = id.descending('message')
    local id2 = id.descending('message')

    assert.is_string(id1)
    assert.is_string(id2)
    assert.is_true(vim.startswith(id1, 'msg_'))
    assert.is_true(vim.startswith(id2, 'msg_'))
    assert.is_not.equal(id1, id2)
  end)

  it('should validate given IDs correctly', function()
    local given_id = id.ascending('user', 'usr_existing123')
    assert.equal(given_id, 'usr_existing123')
  end)

  it('should throw error for invalid given IDs', function()
    assert.has_error(function()
      id.ascending('user', 'invalid_prefix')
    end)
  end)

  it('should validate schemas correctly', function()
    local session_id = id.ascending('session')
    local schema_check = id.schema('session')

    local valid, err = schema_check(session_id)
    assert.is_true(valid)
    assert.is_nil(err)

    local invalid_valid, invalid_err = schema_check('msg_invalid')
    assert.is_false(invalid_valid)
    assert.is_string(invalid_err)
  end)

  it('should return available prefixes', function()
    local prefixes = id.get_prefixes()

    assert.is_table(prefixes)
    assert.equal(prefixes.session, 'ses')
    assert.equal(prefixes.message, 'msg')
    assert.equal(prefixes.user, 'usr')
    assert.equal(prefixes.part, 'prt')
    assert.equal(prefixes.permission, 'per')
  end)

  it('should generate IDs with correct length structure', function()
    local session_id = id.ascending('session')

    assert.equals(30, #session_id)
    assert.matches('^ses_[0-9a-f][0-9a-f]+[0-9A-Za-z]+$', session_id)
  end)

  describe('V1 native time encoding', function()
    local original_gettimeofday

    before_each(function()
      original_gettimeofday = vim.uv.gettimeofday
      vim.uv.gettimeofday = function()
        return 1700000000, 123000
      end
      package.loaded['opencode.id'] = nil
      id = require('opencode.id')
    end)

    after_each(function()
      vim.uv.gettimeofday = original_gettimeofday
      package.loaded['opencode.id'] = nil
      id = require('opencode.id')
    end)

    it(
      'uses wall-clock milliseconds, a shared same-millisecond counter, and the 48-bit descending complement',
      function()
        local first = id.ascending('message')
        local second = id.ascending('message')
        local descending = id.descending('message')

        assert.equals('bcfe5687b001', first:sub(5, 16))
        assert.equals('bcfe5687b002', second:sub(5, 16))
        assert.equals('4301a9784ffc', descending:sub(5, 16))
        assert.is_true(first < second)
        assert.matches('^msg_[0-9a-f][0-9a-f]+[0-9A-Za-z]+$', first)
        assert.equals(30, #first)
      end
    )
  end)
end)
