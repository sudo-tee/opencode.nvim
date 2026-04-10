local assert = require('luassert')
local command_parse = require('opencode.commands.parse')
local commands = require('opencode.commands')

describe('opencode.commands.parse', function()
  it('parses empty args to toggle intent', function()
    local result = command_parse.command({ args = '', range = 0 }, commands.get_commands())

    assert.is_true(result.ok)
    assert.equal('toggle', result.intent.name)
    assert.same({}, result.intent.args)
    assert.is_nil(result.intent.range)
    assert.same({
      raw_args = '',
      argv = {},
    }, result.intent.source)
  end)

  it('returns stable unknown subcommand parse error', function()
    local result = command_parse.command({ args = 'not_real', range = 0 }, commands.get_commands())

    assert.is_false(result.ok)
    assert.same({
      code = 'unknown_subcommand',
      message = 'Unknown subcommand: not_real',
      subcommand = 'not_real',
    }, result.error)
    assert.is_nil(result.intent)
  end)

  it('parses range and argv without executing handlers', function()
    local result = command_parse.command({
      args = 'quick_chat hello world',
      range = 2,
      line1 = 3,
      line2 = 6,
    }, commands.get_commands())

    assert.is_true(result.ok)
    assert.equal('quick_chat', result.intent.name)
    assert.same({ 'hello', 'world' }, result.intent.args)
    assert.same({ start = 3, stop = 6 }, result.intent.range)
    assert.same({
      raw_args = 'quick_chat hello world',
      argv = { 'quick_chat', 'hello', 'world' },
    }, result.intent.source)
  end)

  it('keeps diff default open behavior when nested subcommand is omitted', function()
    local result = command_parse.command({ args = 'diff', range = 0 }, commands.get_commands())

    assert.is_true(result.ok)
    assert.equal('diff', result.intent.name)
    assert.same({}, result.intent.args)
  end)

  it('validates nested subcommand from command schema without hardcoded command names', function()
    local defs = {
      custom = {
        desc = 'custom command',
        execute = function() end,
        completions = { 'run' },
        nested_subcommand = { allow_empty = false },
      },
    }

    local result = command_parse.command({ args = 'custom', range = 0 }, defs)

    assert.is_false(result.ok)
    assert.same({
      code = 'invalid_subcommand',
      message = 'Invalid custom subcommand. Use: run',
      subcommand = 'custom',
    }, result.error)
  end)
end)
