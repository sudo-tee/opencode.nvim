local output_diff = require('opencode.ui.renderer.output_diff')

describe('renderer.output_diff.unchanged_prefix_lines', function()
  it('returns full length when both inputs are identical', function()
    assert.equals(3, output_diff.unchanged_prefix_lines({ lines = { 'a', 'b', 'c' } }, { lines = { 'a', 'b', 'c' } }))
  end)

  it('returns 0 when first line differs', function()
    assert.equals(0, output_diff.unchanged_prefix_lines({ lines = { 'a' } }, { lines = { 'b' } }))
  end)

  it('returns the count of identical leading lines', function()
    assert.equals(2, output_diff.unchanged_prefix_lines({ lines = { 'a', 'b', 'c' } }, { lines = { 'a', 'b', 'x' } }))
  end)

  it('clamps to the shorter of the two', function()
    assert.equals(1, output_diff.unchanged_prefix_lines({ lines = { 'a', 'b' } }, { lines = { 'a' } }))
    assert.equals(1, output_diff.unchanged_prefix_lines({ lines = { 'a' } }, { lines = { 'a', 'b' } }))
  end)

  it('handles nil inputs', function()
    assert.equals(0, output_diff.unchanged_prefix_lines(nil, { lines = { 'a' } }))
    assert.equals(0, output_diff.unchanged_prefix_lines({ lines = { 'a' } }, nil))
  end)
end)

describe('renderer.output_diff.is_unchanged', function()
  it('returns false when prev is nil', function()
    assert.is_false(output_diff.is_unchanged(nil, { lines = {}, extmarks = {} }))
  end)

  it('returns true when lines and extmarks are identical', function()
    assert.is_true(
      output_diff.is_unchanged({ lines = { 'a', 'b' }, extmarks = {} }, { lines = { 'a', 'b' }, extmarks = {} })
    )
  end)

  it('returns false when line count differs', function()
    assert.is_false(
      output_diff.is_unchanged({ lines = { 'a' }, extmarks = {} }, { lines = { 'a', 'b' }, extmarks = {} })
    )
  end)

  it('returns false when any line content differs', function()
    assert.is_false(
      output_diff.is_unchanged({ lines = { 'a', 'b' }, extmarks = {} }, { lines = { 'a', 'X' }, extmarks = {} })
    )
  end)

  it('returns false when extmarks differ on an existing line', function()
    assert.is_false(
      output_diff.is_unchanged(
        { lines = { 'a' }, extmarks = { [0] = { { line_hl_group = 'A' } } } },
        { lines = { 'a' }, extmarks = { [0] = { { line_hl_group = 'B' } } } }
      )
    )
  end)

  it('returns false when negative-line extmarks differ', function()
    assert.is_false(
      output_diff.is_unchanged(
        { lines = { 'a' }, extmarks = { [-1] = { { virt_text = { { 'old' } } } } } },
        { lines = { 'a' }, extmarks = { [-1] = { { virt_text = { { 'new' } } } } } }
      )
    )
  end)

  it('returns false when extmark is added on a new line', function()
    assert.is_false(
      output_diff.is_unchanged(
        { lines = { 'a', 'b' }, extmarks = {} },
        { lines = { 'a', 'b' }, extmarks = { [1] = { { line_hl_group = 'A' } } } }
      )
    )
  end)
end)

describe('renderer.output_diff.slice_lines', function()
  it('returns the tail from start_idx (1-based)', function()
    assert.same({ 'b', 'c' }, output_diff.slice_lines({ 'a', 'b', 'c' }, 2))
  end)

  it('returns empty when start_idx exceeds length', function()
    assert.same({}, output_diff.slice_lines({ 'a', 'b' }, 5))
  end)

  it('handles nil input', function()
    assert.same({}, output_diff.slice_lines(nil, 1))
  end)
end)

describe('renderer.output_diff.slice_extmarks', function()
  it('shifts non-negative keys by -start_line', function()
    local out = output_diff.slice_extmarks({ [2] = { { id = 'm' } } }, 2)
    assert.same({ [0] = { { id = 'm' } } }, out)
  end)

  it('preserves negative keys untouched', function()
    local out = output_diff.slice_extmarks({ [-1] = { { id = 'n' } } }, 5)
    assert.same({ [-1] = { { id = 'n' } } }, out)
  end)

  it('drops keys below start_line', function()
    local out = output_diff.slice_extmarks({ [1] = { { id = 'a' } }, [3] = { { id = 'b' } } }, 2)
    assert.same({ [1] = { { id = 'b' } } }, out)
  end)
end)

describe('renderer.output_diff.is_append_only', function()
  it('returns true when new lines tail-extend old lines', function()
    assert.is_true(output_diff.is_append_only({ 'a', 'b' }, { 'a', 'b', 'c' }))
  end)

  it('returns false when the tail differs', function()
    assert.is_false(output_diff.is_append_only({ 'a', 'b' }, { 'a', 'X', 'c' }))
  end)

  it('returns false when new is not strictly longer', function()
    assert.is_false(output_diff.is_append_only({ 'a', 'b' }, { 'a', 'b' }))
    assert.is_false(output_diff.is_append_only({ 'a', 'b' }, { 'a' }))
  end)
end)
