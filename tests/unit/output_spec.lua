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
end)
