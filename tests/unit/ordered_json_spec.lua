local OrderedJson = require('opencode.ordered_json')
local tmpfile = '/tmp/opencode_test_ordered.json'

local function cleanup()
  os.remove(tmpfile)
end

describe('OrderedJson', function()
  before_each(function()
    cleanup()
  end)

  after_each(function()
    cleanup()
  end)

  it('creates a new instance', function()
    local ordered_json = OrderedJson.new()
    assert.are.equal(type(ordered_json), 'table')
    assert.are.equal(getmetatable(ordered_json), OrderedJson)
  end)

  it('detects arrays correctly', function()
    local ordered_json = OrderedJson.new()
    assert.is_true(ordered_json:is_array({ 1, 2, 3 }))
    assert.is_false(ordered_json:is_array({ a = 1, b = 2 }))
    assert.is_false(ordered_json:is_array('not a table'))
    assert.is_false(ordered_json:is_array({}))
  end)

  it('reads JSON and preserves key order', function()
    local f = assert(io.open(tmpfile, 'w'))
    f:write('{"b": 2, "a": 1, "c": 3}')
    f:close()
    local ordered_json = OrderedJson.new()
    local result = ordered_json:read(tmpfile)
    assert.are.same(result.data, { b = 2, a = 1, c = 3 })
    assert.are.same(result._ordered_keys, { 'b', 'a', 'c' })
  end)

  it('encodes table with preserved key order', function()
    local ordered_json = OrderedJson.new()
    local obj = { data = { b = 2, a = 1, c = 3 }, _ordered_keys = { 'b', 'a', 'c' } }
    local json_str = ordered_json:encode(obj)
    -- Should start with b, then a, then c
    local b_pos = json_str:find('"b":')
    local a_pos = json_str:find('"a":')
    local c_pos = json_str:find('"c":')
    assert.is_true(b_pos < a_pos and a_pos < c_pos)
  end)
end)
