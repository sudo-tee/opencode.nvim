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

describe('util.parse_run_args', function()
  it('parses no prefixes', function()
    local opts, prompt = util.parse_run_args({ 'just', 'a', 'regular', 'prompt' })
    assert.are.same({}, opts)
    assert.equals('just a regular prompt', prompt)
  end)

  it('parses single agent prefix', function()
    local opts, prompt = util.parse_run_args({ 'agent=plan', 'hello', 'world' })
    assert.are.same({ agent = 'plan' }, opts)
    assert.equals('hello world', prompt)
  end)

  it('parses single model prefix', function()
    local opts, prompt = util.parse_run_args({ 'model=openai/gpt-4', 'analyze', 'this' })
    assert.are.same({ model = 'openai/gpt-4' }, opts)
    assert.equals('analyze this', prompt)
  end)

  it('parses single context prefix', function()
    local opts, prompt = util.parse_run_args({ 'context=current_file.enabled=false', 'test' })
    assert.are.same({ context = { current_file = { enabled = false } } }, opts)
    assert.equals('test', prompt)
  end)

  it('parses multiple prefixes in order', function()
    local opts, prompt = util.parse_run_args({ 'agent=plan', 'model=openai/gpt-4', 'context=current_file.enabled=false', 'prompt', 'here' })
    assert.are.same({
      agent = 'plan',
      model = 'openai/gpt-4',
      context = { current_file = { enabled = false } }
    }, opts)
    assert.equals('prompt here', prompt)
  end)

  it('parses context with multiple comma-delimited values', function()
    local opts, prompt = util.parse_run_args({ 'context=current_file.enabled=false,selection.enabled=true', 'test' })
    assert.are.same({
      context = {
        current_file = { enabled = false },
        selection = { enabled = true }
      }
    }, opts)
    assert.equals('test', prompt)
  end)

  it('handles empty prompt after prefixes', function()
    local opts, prompt = util.parse_run_args({ 'agent=plan' })
    assert.are.same({ agent = 'plan' }, opts)
    assert.equals('', prompt)
  end)

  it('handles empty string', function()
    local opts, prompt = util.parse_run_args({})
    assert.are.same({}, opts)
    assert.equals('', prompt)
  end)

  it('stops parsing at first non-prefix token', function()
    local opts, prompt = util.parse_run_args({ 'agent=plan', 'some', 'prompt', 'model=openai/gpt-4' })
    assert.are.same({ agent = 'plan' }, opts)
    assert.equals('some prompt model=openai/gpt-4', prompt)
  end)
end)
