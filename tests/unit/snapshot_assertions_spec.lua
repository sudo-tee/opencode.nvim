local assert = require('luassert')
local snapshots = require('tests.snapshot_assertions')

---@param json string
---@return table
local function snapshot(json)
  return { lines = { 'Input', '`````json', json, '`````' }, extmarks = {}, actions = {} }
end

describe('snapshot JSON comparison', function()
  it('ignores object key order, including nested objects, without changing snapshots', function()
    local expected = snapshot('{"error":"bad","tool":{"a":1,"b":2}}')
    local actual = snapshot('{"tool":{"b":2,"a":1},"error":"bad"}')
    local original = vim.deepcopy(actual)

    snapshots.assert_same(expected, actual)

    assert.same(original, actual)
  end)

  it('rejects changed values', function()
    assert.has_error(function()
      snapshots.assert_same(snapshot('{"a":1}'), snapshot('{"a":2}'))
    end)
  end)

  it('ignores equivalent JSON slash escaping across Neovim versions', function()
    snapshots.assert_same(snapshot('{"path":"a\\/b"}'), snapshot('{"path":"a/b"}'))
  end)

  it('preserves array order', function()
    assert.has_error(function()
      snapshots.assert_same(snapshot('[1,2]'), snapshot('[2,1]'))
    end)
  end)

  it('keeps JSON-looking text outside JSON fences exact', function()
    assert.has_error(function()
      snapshots.assert_same({ lines = { '{"a":1,"b":2}' } }, { lines = { '{"b":2,"a":1}' } })
    end)
  end)

  it('keeps malformed JSON exact and distinct from decoded strings', function()
    snapshots.assert_same(snapshot('not JSON'), snapshot('not JSON'))
    assert.has_error(function()
      snapshots.assert_same(snapshot('"text"'), snapshot('text'))
    end)
  end)

  it('compares multiline JSON objects structurally', function()
    snapshots.assert_same(
      { lines = { '```json', '{', '"a":1,"b":2', '}', '```' } },
      { lines = { '```json', '{', '"b":2,"a":1', '}', '```' } }
    )
  end)

  it('retains exact extmark, action, and line-position comparisons', function()
    local expected = snapshot('{"a":1,"b":2}')
    local actual = snapshot('{"b":2,"a":1}')
    actual.extmarks = { { 1, 2, 0, {} } }
    assert.has_error(function()
      snapshots.assert_same(expected, actual)
    end)
    actual.extmarks = {}
    actual.actions = { { type = 'changed' } }
    assert.has_error(function()
      snapshots.assert_same(expected, actual)
    end)
    actual.actions = {}
    table.insert(actual.lines, 3, '')
    assert.has_error(function()
      snapshots.assert_same(expected, actual)
    end)
  end)
end)
