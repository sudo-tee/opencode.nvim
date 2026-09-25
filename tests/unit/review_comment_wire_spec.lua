local decode = require('opencode.protocols.observation').decode_editor_context
local formatter = require('opencode.ui.formatter')

describe('review comment wire context', function()
  it('decodes grouped comments and renders each under its line range', function()
    local payload = vim.json.encode({
      context_type = 'review-comment', file = 'src/one.lua',
      comments = {
        { comment = 'First', side = 'after', lines = '2-2', code = 'alpha' },
        { comment = 'Second', side = 'before', lines = '4-5', code = 'beta' },
      },
    })
    local part, err = decode('review-comment', payload, 'grouped', true, false)
    assert.is_nil(err)
    assert.same({ kind = 'review_comment', file_name = 'src/one.lua' }, part.source)
    local output = formatter.format_part(part, { kind = 'user', content = { part } }, true)
    local rendered = table.concat(output:get_lines(), '\n')
    assert.is_true(rendered:find('Lines 2-2 (after):\nFirst\n`````lua\nalpha', 1, true) ~= nil)
    assert.is_true(rendered:find('Lines 4-5 (before):\nSecond\n`````lua\nbeta', 1, true) ~= nil)
  end)

  it('decodes compact sent comments and renders feedback above code', function()
    local payload = vim.json.encode({
      context_type = 'review-comment',
      comment = 'Please simplify',
      file = 'src/one.lua', side = 'before', lines = '4-5', code = 'local x = 1',
    })
    local part, err = decode('review-comment', payload, 'part', true, false)
    assert.is_nil(err)
    assert.same({ kind = 'review_comment', file_name = 'src/one.lua', range = '4-5', side = 'before' }, part.source)
    assert.equals('Please simplify', part.text)
    local output = formatter.format_part(part, { kind = 'user', content = { part } }, true)
    local lines = output:get_lines()
    assert.is_true(table.concat(lines, '\n'):find('Please simplify', 1, true) ~= nil)
    assert.is_true(table.concat(lines, '\n'):find('local x = 1', 1, true) ~= nil)
  end)

  it('still decodes earlier nested snapshot comments in history', function()
    local payload = vim.json.encode({
      context_type = 'review-comment', comment = 'Old review',
      file = { name = 'src/one.lua', path = '/tmp/src/one.lua' },
      snapshot = { side = 'after', lines = '2-2', code = 'previous' },
    })
    local part, err = decode('review-comment', payload, 'old-part', true, false)
    assert.is_nil(err)
    assert.equals('previous', part.code)
    assert.equals('after', part.source.side)
  end)
end)
