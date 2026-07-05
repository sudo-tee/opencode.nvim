local Output = require('opencode.ui.output')

describe('Output targets', function()
  it('initializes and appends targets', function()
    local output = Output.new()

    output:add_target({
      kind = 'file',
      path = 'README.md',
      range = { line = 1, start_col = 0, end_col = 9 },
    })
    output:add_targets({
      {
        kind = 'symbol',
        token = 'setup',
        candidate_files = { 'README.md' },
        range = { line = 1, start_col = 10, end_col = 15 },
      },
    })

    assert.equals(2, #output.targets)
    assert.equals('README.md', output.targets[1].path)
    assert.equals('setup', output.targets[2].token)
  end)

  it('clears targets with the rest of the carrier data', function()
    local output = Output.new()
    output:add_line('README.md')
    output:add_extmark(1, { hl_group = 'OpencodeFile' })
    output:add_action({ text = 'Open', type = 'diff_open', key = 'o' })
    output:add_target({
      kind = 'file',
      path = 'README.md',
      range = { line = 1, start_col = 0, end_col = 9 },
    })

    output:clear()

    assert.equals(0, #output.lines)
    assert.is_true(vim.tbl_isempty(output.extmarks))
    assert.equals(0, #output.actions)
    assert.equals(0, #output.targets)
  end)

  describe('splitting against embedded newlines', function()
    it('splits a multi-line add_line into multiple lines', function()
      local output = Output.new()
      output:add_line('yes')
      output:add_line('no\nway')
      output:add_line('windows\r\nline')
      output:add_line('a\n\nb')
      assert.are.same({
        'yes',
        'no',
        'way',
        'windows',
        'line',
        'a',
        '',
        'b',
      }, output:get_lines())
    end)

    it('preserves a lone \\r in the line (rare; not split)', function()
      -- Lua patterns lack regex alternation, so vim.split cannot
      -- match \r\n, \r, and \n in one shot. We split on \r?\n which
      -- covers \n and \r\n (the conventions any modern system
      -- produces); a bare \r (old Mac line ending) is kept verbatim.
      -- It's harmless: nvim_buf_set_lines only rejects \n.
      local output = Output.new()
      output:add_line('also\rcr')
      assert.are.same({ 'also\rcr' }, output:get_lines())
    end)

    it('returns the first-line index so extmarks land on the heading line', function()
      local output = Output.new()
      local first = output:add_line('heading\nbody1\nbody2')
      assert.are.equal(1, first)
      assert.are.equal(3, #output.lines)
      -- Caller can add the extmark on the heading line.
      output:add_extmark(first - 1, { line_hl_group = 'X' })
      assert.are.equal('X', output.extmarks[0][1].line_hl_group)
      assert.is_nil(output.extmarks[1])
      assert.is_nil(output.extmarks[2])
    end)

    it('splits each entry when going through add_lines', function()
      local output = Output.new()
      output:add_lines({ 'plain', 'embedded\nnewline', 'mixed\r\nends' })
      assert.are.same({ 'plain', 'embedded', 'newline', 'mixed', 'ends' }, output:get_lines())
    end)

    it('splits entries inside add_lines when a prefix is provided', function()
      local output = Output.new()
      output:add_lines({ 'one', 'two\nthree' }, '> ')
      assert.are.same({ '> one', '> two', '> three' }, output:get_lines())
    end)

    it('treats nil and empty strings as a single blank line', function()
      local output = Output.new()
      output:add_line(nil)
      output:add_line('x')
      output:add_line(nil)
      output:add_line('')
      assert.are.same({ '', 'x', '', '' }, output:get_lines())
    end)

    it('never produces a line containing newlines', function()
      -- The crash we're guarding against is nvim_buf_set_lines rejecting
      -- items with embedded newlines. Lone \r is preserved by design
      -- (see the dedicated test above) and is harmless to the buffer.
      local output = Output.new()
      output:add_line('server-supplied')
      output:add_line('with\nembedded\nnewlines')
      output:add_lines({ 'still\nbad', 'cr\rhere', 'mixed\r\nends' })

      for i, line in ipairs(output:get_lines()) do
        assert.is_nil(line:find('\n'), 'line ' .. i .. ' contains \\n: ' .. vim.inspect(line))
      end
    end)
  end)
end)
