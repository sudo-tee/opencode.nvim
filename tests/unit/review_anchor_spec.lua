local anchor = require('opencode.review_anchor')

local function comment(side)
  return {
    id = 1,
    file = '/tmp/review.lua',
    side = side or 'after',
    start_line = 2,
    end_line = 2,
    code = 'target',
    comment = 'Check this',
    session_id = 'session',
    context_before = { 'before' },
    context_after = { 'after' },
    anchor_side_line = 2,
  }
end

describe('review snapshot anchors', function()
  it('resolves unchanged, moved and duplicate code using context and hint', function()
    local item = comment()
    assert.same(
      { status = 'exact', start_line = 2, end_line = 2 },
      anchor.resolve(item, { 'before', 'target', 'after' })
    )
    assert.same(
      { status = 'moved', start_line = 3, end_line = 3 },
      anchor.resolve(item, { 'prefix', 'before', 'target', 'after' })
    )
    assert.same(
      { status = 'moved', start_line = 6, end_line = 6 },
      anchor.resolve(item, { 'other', 'target', 'other', 'prefix', 'before', 'target', 'after' })
    )
    item.context_before, item.context_after = {}, {}
    assert.same(
      { status = 'moved', start_line = 5, end_line = 5 },
      anchor.resolve(item, { 'target', 'other', 'other', 'other', 'target' }, 5)
    )
  end)

  it('reports modified or removed code around snapshot context, including removed-side comments', function()
    local item = comment()
    assert.same(
      { status = 'modified', start_line = 2, end_line = 2, current_code = 'replacement' },
      anchor.resolve(item, { 'before', 'replacement', 'after' })
    )
    assert.same({ status = 'removed' }, anchor.resolve(item, { 'rewritten' }))
    item.side = 'before'
    assert.same(
      { status = 'modified', start_line = 2, end_line = 1, current_code = '' },
      anchor.resolve(item, { 'before', 'after' })
    )
  end)

  it('finds the nearest changed block among repeated context in a long file', function()
    local item = comment('before')
    item.anchor_side_line = 3000
    local lines = {}
    for index = 1, 4000 do
      lines[index] = index % 2 == 1 and 'before' or 'different'
    end
    lines[3002] = 'after'
    assert.same({ status = 'modified', start_line = 3000, end_line = 3001,
      current_code = 'different\nbefore' }, anchor.resolve(item, lines))
  end)

  it('prefers loaded unsaved buffer and reports missing files', function()
    local path = vim.fn.tempname() .. '.lua'
    vim.fn.writefile({ 'before', 'target', 'after' }, path)
    local item = comment()
    item.file = path
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { 'replacement' })
    assert.equals('modified', anchor.current(item).status)
    vim.api.nvim_buf_delete(buf, { force = true })
    assert.equals('exact', anchor.current(item).status)
    vim.fn.delete(path)
    assert.equals('missing_file', anchor.current(item).status)
  end)

  it('translates line hints through later hunks', function()
    assert.equals(7, anchor.translate(5, '@@ -2,1 +2,3 @@\n-old\n+a\n+b\n+c'))
    assert.equals(2, anchor.translate(3, '@@ -3,2 +2,1 @@\n-old\n-old\n+new'))
  end)
end)
