local util = require('opencode.util')

describe('util.parse_dot_args', function()
  it('parses flat booleans', function()
    local args = util.parse_dot_args('context=false foo=true')
    assert.are.same({ context = false, foo = true }, args)
  end)

  it('parses nested dot notation', function()
    local args = util.parse_dot_args('context.enabled=false context.selection.enabled=true')
    assert.are.same({ context = { enabled = false, selection = { enabled = true } } }, args)
  end)

  it('parses mixed nesting and booleans', function()
    local args = util.parse_dot_args('context=false context.enabled=true context.selection.enabled=false foo=bar')
    assert.are.same({ context = { enabled = true, selection = { enabled = false } }, foo = 'bar' }, args)
  end)

  it('parses numbers', function()
    local args = util.parse_dot_args('foo=42 bar=3.14')
    assert.are.same({ foo = 42, bar = 3.14 }, args)
  end)

  it('handles empty string', function()
    local args = util.parse_dot_args('')
    assert.are.same({}, args)
  end)
end)
