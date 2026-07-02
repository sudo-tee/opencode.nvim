local assert = require('luassert')

local symbol_tokens = require('opencode.ui.symbol_tokens')

describe('opencode.ui.symbol_tokens', function()
  it('finds plain and qualified symbol spans', function()
    local cases = {
      { line = 'foo', token = 'foo', start_pos = 1, end_pos = 3 },
      { line = 'foo: call', token = 'foo', start_pos = 1, end_pos = 3 },
      { line = 'foo:call', token = 'foo:call', start_pos = 1, end_pos = 8 },
      { line = 'A::b', token = 'A::b', start_pos = 1, end_pos = 4 },
      { line = 'OpencodeApiClient:_call', token = 'OpencodeApiClient:_call', start_pos = 1, end_pos = 23 },
      { line = 'M.actions.jump_to_file', token = 'M.actions.jump_to_file', start_pos = 1, end_pos = 22 },
      { line = 'foo.', token = 'foo', start_pos = 1, end_pos = 3 },
      { line = 'foo::', token = 'foo', start_pos = 1, end_pos = 3 },
    }

    for _, case in ipairs(cases) do
      local start_pos, end_pos, token = symbol_tokens.find(case.line, 1)
      assert.equal(case.start_pos, start_pos, case.line)
      assert.equal(case.end_pos, end_pos, case.line)
      assert.equal(case.token, token, case.line)
    end
  end)

  it('returns nil token for numeric spans', function()
    local start_pos, end_pos, token = symbol_tokens.find('123', 1)

    assert.equal(1, start_pos)
    assert.equal(3, end_pos)
    assert.is_nil(token)
  end)

  it('returns nil token for path segments', function()
    local cases = {
      { line = 'tests/data/symbol-reference-navigation.json', scan_from = 1, start_pos = 1, end_pos = 5 },
      { line = 'tests/data/symbol-reference-navigation.json', scan_from = 7, start_pos = 7, end_pos = 10 },
      { line = 'tests/data/symbol-reference-navigation.json', scan_from = 12, start_pos = 12, end_pos = 17 },
      { line = '.cache/', scan_from = 1, start_pos = 2, end_pos = 6 },
      { line = 'docs/plans/', scan_from = 1, start_pos = 1, end_pos = 4 },
    }

    for _, case in ipairs(cases) do
      local start_pos, end_pos, token = symbol_tokens.find(case.line, case.scan_from)
      assert.equal(case.start_pos, start_pos, case.line)
      assert.equal(case.end_pos, end_pos, case.line)
      assert.is_nil(token, case.line)
    end
  end)

  it('resolves tokens by zero-based cursor column', function()
    assert.equal('foo', symbol_tokens.at_col('foo: call', 0))
    assert.is_nil(symbol_tokens.at_col('foo: call', 3))
    assert.equal('foo:call', symbol_tokens.at_col('foo:call', 3))
    assert.equal('OpencodeApiClient:_call', symbol_tokens.at_col('OpencodeApiClient:_call', 18))
    assert.equal('A::b', symbol_tokens.at_col('A::b', 1))
    assert.equal('A::b', symbol_tokens.at_col('A::b', 2))
    assert.equal('A::b', symbol_tokens.at_col('A::b', 3))
    assert.equal('M.actions.jump_to_file', symbol_tokens.at_col('M.actions.jump_to_file', 10))
    assert.is_nil(symbol_tokens.at_col('tests/data/symbol-reference-navigation.json', 8))
    assert.is_nil(symbol_tokens.at_col('.cache/', 2))
  end)
end)
