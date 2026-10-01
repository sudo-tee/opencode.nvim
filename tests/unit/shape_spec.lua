local assert = require('luassert')
local shape = require('opencode.shape')

describe('shape validator', function()
  it('validates shorthand object specs and returns original value', function()
    local value = { id = 'message', count = 2 }

    assert.equals(value, shape.validate(value, { id = 'string', count = 'number' }))
    assert.equals(value, shape(value, { id = 'string', count = 'number' }))
    assert.is_true(shape.check(value, { id = 'string', count = 'number' }))
    assert.is_false(shape.check({ id = 42 }, { id = 'string' }))
  end)

  it('raises through expect and returns successful conditions', function()
    assert.is_true(shape.expect(true, 'unused'))
    assert.has_error(function()
      shape.expect(false, 'invalid value')
    end, 'invalid value')
  end)

  it('treats an empty table rule as an object, not an empty enum', function()
    local schema = shape.object({ metadata = {} })

    assert.is_true(schema:is({ metadata = {} }))
    assert.is_true(schema:is({ metadata = { source = 'server' } }))
    assert.is_false(schema:is({ metadata = 'server' }))
  end)

  it('supports optional fields and arrays', function()
    local schema = shape.object({
      name = shape.string(),
      tags = shape.optional(shape.array(shape.string())),
      metadata = shape.table(),
    })

    assert.is_false(schema:is({ name = 'item' }))
    assert.is_true(schema:is({ name = 'item', metadata = {} }))
    assert.is_true(schema:is({ name = 'item', metadata = {}, tags = { 'one', 'two' } }))
    assert.is_false(schema:is({ name = 'item', metadata = {}, tags = { 'one', 2 } }))
    assert.is_false(schema:is({ name = 'item', metadata = {}, tags = { [2] = 'two' } }))
  end)

  it('supports enum, literal, union, and custom schemas', function()
    local schema = shape.union(
      shape.literal('queued'),
      shape.enum({ 'running', 'completed' }),
      shape.custom(function(value)
        return type(value) == 'string' and value:match('^failed:') ~= nil
      end, 'failure state')
    )

    assert.is_true(schema:is('queued'))
    assert.is_true(schema:is('running'))
    assert.is_true(schema:is('failed:timeout'))
    assert.is_false(schema:is('unknown'))
  end)

  it('supports numeric bounds and cross-field constraints', function()
    local schema = shape
      .object({
        start = shape.integer():min(0),
        finish = shape.integer():min(0),
      })
      :constraint(function(value)
        return value.finish >= value.start
      end)

    assert.is_true(schema:is({ start = 1, finish = 2 }))
    assert.is_false(schema:is({ start = -1, finish = 2 }))
    assert.is_false(schema:is({ start = 3, finish = 2 }))
    assert.is_false(shape.integer():max(10):is(11))
  end)

  it('supports safe parsing and schema method chaining', function()
    local schema = shape.string():optional():array()
    local valid = schema:safe_parse({ 'one', 'two' })
    local invalid = schema:safe_parse({ 'one', 2 })

    assert.is_true(valid.success)
    assert.same({ 'one', 'two' }, valid.data)
    assert.is_false(invalid.success)
    assert.is_string(invalid.error)
  end)

  it('transforms validated values, including nested fields', function()
    local number_conversion = shape.string():convert(tonumber)
    assert.equals(42, number_conversion:parse('42'))
    assert.is_false(number_conversion:is(42))
    assert.has_error(function()
      number_conversion:parse('not-a-number')
    end)

    local schema = shape
      .object({
        id = shape.string(),
        cents = shape.number():convert(function(value)
          return value * 100
        end),
      })
      :transform(function(value)
        return { key = value.id, amount = value.cents }
      end)

    local input = { id = 'invoice', cents = 12.5 }
    assert.same({ key = 'invoice', amount = 1250 }, schema:parse(input))
    assert.same(input, { id = 'invoice', cents = 12.5 })
    assert.is_false(schema:is({ id = 'invoice', cents = '12.5' }))
  end)

  it('can reject unknown object fields in strict mode', function()
    local schema = shape.strict_object({ id = 'string' })

    assert.is_true(schema:is({ id = 'message' }))
    assert.is_false(schema:is({ id = 'message', extra = true }))
  end)
end)
