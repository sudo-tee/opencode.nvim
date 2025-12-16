local search_replace = require('opencode.quick_chat.search_replace')

describe('search_replace.parse_blocks', function()
  it('parses a single SEARCH/REPLACE block', function()
    local input = [[
<<<<<<< SEARCH
local x = 1
=======
local x = 2
>>>>>>> REPLACE
]]
    local replacements, warnings = search_replace.parse_blocks(input)

    assert.equals(1, #replacements)
    assert.equals(0, #warnings)
    assert.equals('local x = 1', replacements[1].search)
    assert.equals('local x = 2', replacements[1].replace)
    assert.equals(1, replacements[1].block_number)
  end)

  it('parses multiple SEARCH/REPLACE blocks', function()
    local input = [[
<<<<<<< SEARCH
local x = 1
=======
local x = 2
>>>>>>> REPLACE

<<<<<<< SEARCH
function foo()
  return 42
end
=======
function foo()
  return 100
end
>>>>>>> REPLACE
]]
    local replacements, warnings = search_replace.parse_blocks(input)

    assert.equals(2, #replacements)
    assert.equals(0, #warnings)
    assert.equals('local x = 1', replacements[1].search)
    assert.equals('local x = 2', replacements[1].replace)
    assert.equals(1, replacements[1].block_number)
    assert.equals('function foo()\n  return 42\nend', replacements[2].search)
    assert.equals('function foo()\n  return 100\nend', replacements[2].replace)
    assert.equals(2, replacements[2].block_number)
  end)

  it('handles code fences around blocks', function()
    local input = [[
```
<<<<<<< SEARCH
local x = 1
=======
local x = 2
>>>>>>> REPLACE
```
]]
    local replacements, warnings = search_replace.parse_blocks(input)

    assert.equals(1, #replacements)
    assert.equals(0, #warnings)
    assert.equals('local x = 1', replacements[1].search)
  end)

  it('handles code fences with language specifier', function()
    local input = [[
```lua
<<<<<<< SEARCH
local x = 1
=======
local x = 2
>>>>>>> REPLACE
```
]]
    local replacements, warnings = search_replace.parse_blocks(input)

    assert.equals(1, #replacements)
    assert.equals(0, #warnings)
  end)

  it('warns on missing separator', function()
    local input = [[
<<<<<<< SEARCH
local x = 1
>>>>>>> REPLACE
]]
    local replacements, warnings = search_replace.parse_blocks(input)

    assert.equals(0, #replacements)
    assert.equals(1, #warnings)
    assert.matches('Missing separator', warnings[1])
  end)

  it('warns on missing end marker', function()
    local input = [[
<<<<<<< SEARCH
local x = 1
=======
local x = 2
]]
    local replacements, warnings = search_replace.parse_blocks(input)

    assert.equals(0, #replacements)
    assert.equals(1, #warnings)
    assert.matches('Missing end marker', warnings[1])
  end)

  it('parses empty SEARCH section as insert operation', function()
    -- Empty search means "insert at cursor position"
    local input = [[
<<<<<<< SEARCH

=======
local x = 2
>>>>>>> REPLACE
]]
    local replacements, warnings = search_replace.parse_blocks(input)

    assert.equals(1, #replacements)
    assert.equals(0, #warnings)
    assert.equals('', replacements[1].search)
    assert.equals('local x = 2', replacements[1].replace)
    assert.is_true(replacements[1].is_insert)
  end)

  it('parses whitespace-only SEARCH section as insert operation', function()
    -- Note: Empty search with content on same line as separator
    -- The parser requires \n======= so whitespace-only search still needs proper structure
    local input = [[
<<<<<<< SEARCH
   
=======
local x = 2
>>>>>>> REPLACE
]]
    local replacements, warnings = search_replace.parse_blocks(input)

    assert.equals(1, #replacements)
    assert.equals(0, #warnings)
    assert.equals('', replacements[1].search)
    assert.is_true(replacements[1].is_insert)
  end)

  it('handles empty REPLACE section (deletion)', function()
    -- Note: Empty replace needs proper newline structure
    local input = [[
<<<<<<< SEARCH
local unused = true
=======

>>>>>>> REPLACE
]]
    local replacements, warnings = search_replace.parse_blocks(input)

    assert.equals(1, #replacements)
    assert.equals(0, #warnings)
    assert.equals('local unused = true', replacements[1].search)
    -- Replace section contains single empty line
    assert.equals('', replacements[1].replace)
  end)

  it('normalizes CRLF line endings', function()
    local input = "<<<<<<< SEARCH\r\nlocal x = 1\r\n=======\r\nlocal x = 2\r\n>>>>>>> REPLACE\r\n"
    local replacements, warnings = search_replace.parse_blocks(input)

    assert.equals(1, #replacements)
    assert.equals(0, #warnings)
    assert.equals('local x = 1', replacements[1].search)
  end)

  it('handles extra angle brackets in markers', function()
    local input = [[
<<<<<<<< SEARCH
local x = 1
=======
local x = 2
>>>>>>>> REPLACE
]]
    local replacements, warnings = search_replace.parse_blocks(input)

    assert.equals(1, #replacements)
    assert.equals(0, #warnings)
  end)

  it('ignores text before first block', function()
    local input = [[
Here is my response explaining the changes:

<<<<<<< SEARCH
local x = 1
=======
local x = 2
>>>>>>> REPLACE
]]
    local replacements, warnings = search_replace.parse_blocks(input)

    assert.equals(1, #replacements)
    assert.equals(0, #warnings)
    assert.equals('local x = 1', replacements[1].search)
  end)

  it('ignores text between blocks', function()
    local input = [[
<<<<<<< SEARCH
local x = 1
=======
local x = 2
>>>>>>> REPLACE

And here is another change:

<<<<<<< SEARCH
local y = 3
=======
local y = 4
>>>>>>> REPLACE
]]
    local replacements, warnings = search_replace.parse_blocks(input)

    assert.equals(2, #replacements)
    assert.equals(0, #warnings)
  end)

  it('returns empty array for no blocks', function()
    local input = 'Just some regular text with no blocks'
    local replacements, warnings = search_replace.parse_blocks(input)

    assert.equals(0, #replacements)
    assert.equals(0, #warnings)
  end)

  it('requires at least 7 angle brackets', function()
    local input = [[
<<<<<< SEARCH
local x = 1
=======
local x = 2
>>>>>> REPLACE
]]
    local replacements, warnings = search_replace.parse_blocks(input)

    assert.equals(0, #replacements)
    assert.equals(0, #warnings)
  end)
end)

describe('search_replace.apply', function()
  it('applies replacements to buffer', function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'local x = 1', 'local y = 2' })

    local replacements = {
      { search = 'local x = 1', replace = 'local x = 100', block_number = 1 },
    }

    local success, errors, count = search_replace.apply(buf, replacements)

    assert.is_true(success)
    assert.equals(0, #errors)
    assert.equals(1, count)

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.are.same({ 'local x = 100', 'local y = 2' }, lines)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it('returns error for invalid buffer', function()
    local success, errors, count = search_replace.apply(99999, {})

    assert.is_false(success)
    assert.equals(1, #errors)
    assert.matches('Buffer is not valid', errors[1])
    assert.equals(0, count)
  end)

  it('does not modify buffer if no matches', function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'local x = 1' })

    local replacements = {
      { search = 'local y = 2', replace = 'local y = 200', block_number = 1 },
    }

    local success, errors, count = search_replace.apply(buf, replacements)

    assert.is_false(success)
    assert.equals(1, #errors)
    assert.equals(0, count)

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.are.same({ 'local x = 1' }, lines)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it('inserts at cursor row when is_insert is true', function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'line 1', 'line 2', 'line 3' })

    local replacements = {
      { search = '', replace = 'inserted text', block_number = 1, is_insert = true },
    }

    -- Insert before row 1 (0-indexed), so inserts before "line 2"
    local success, errors, count = search_replace.apply(buf, replacements, 1)

    assert.is_true(success)
    assert.equals(0, #errors)
    assert.equals(1, count)

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.are.same({ 'line 1', 'inserted text', 'line 2', 'line 3' }, lines)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it('inserts at empty line cursor position', function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'line 1', '', 'line 3' })

    local replacements = {
      { search = '', replace = 'new content', block_number = 1, is_insert = true },
    }

    -- Insert before row 1 (0-indexed), the empty line
    local success, errors, count = search_replace.apply(buf, replacements, 1)

    assert.is_true(success)
    assert.equals(0, #errors)
    assert.equals(1, count)

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.are.same({ 'line 1', 'new content', '', 'line 3' }, lines)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it('inserts multiline content at cursor row', function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'line 1', '', 'line 3' })

    local replacements = {
      { search = '', replace = 'first\nsecond\nthird', block_number = 1, is_insert = true },
    }

    -- Insert before row 1 (0-indexed)
    local success, errors, count = search_replace.apply(buf, replacements, 1)

    assert.is_true(success)
    assert.equals(0, #errors)
    assert.equals(1, count)

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.are.same({ 'line 1', 'first', 'second', 'third', '', 'line 3' }, lines)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it('returns error for insert without cursor_row', function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'line 1' })

    local replacements = {
      { search = '', replace = 'inserted text', block_number = 1, is_insert = true },
    }

    -- No cursor_row provided
    local success, errors, count = search_replace.apply(buf, replacements)

    assert.is_false(success)
    assert.equals(1, #errors)
    assert.matches('Insert operation requires cursor position', errors[1])
    assert.equals(0, count)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
