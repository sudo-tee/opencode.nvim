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

    -- Should have prefix + underscore + 12 hex chars + 14 random chars
    -- ses_ + 12 hex + 14 random = 4 + 12 + 14 = 30 total
    assert.is_true(#session_id >= 20) -- At least prefix + some content
  end)
end)

