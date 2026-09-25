local comment_input = require('opencode.ui.session_diff.comment_input')

describe('session diff comment input', function()
  it('submits a written comment from the real acwrite float', function()
    local origin = vim.api.nvim_get_current_win()
    local submitted
    comment_input.open({ title = 'file.lua:1-1 (after)', on_submit = function(text) submitted = text end })
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'Review this' })
    vim.cmd('stopinsert')
    vim.cmd('write')
    assert.equals('Review this', submitted)
    assert.equals(origin, vim.api.nvim_get_current_win())
  end)

  it('keeps temporary comment editor free of filetype hooks', function()
    local triggered = false
    local group = vim.api.nvim_create_augroup('OpencodeCommentInputSpec', { clear = true })
    vim.api.nvim_create_autocmd('FileType', {
      pattern = '*', group = group,
      callback = function(args)
        if vim.bo[args.buf].buftype == 'acwrite' then triggered = true end
      end,
    })
    comment_input.open({ title = 'file.lua:1-1 (after)', on_submit = function() end })
    local buf = vim.api.nvim_get_current_buf()
    assert.equals('acwrite', vim.bo[buf].buftype)
    assert.equals('', vim.bo[buf].filetype)
    assert.is_false(vim.b[buf].completion)
    assert.is_false(triggered)
    vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
    vim.api.nvim_del_augroup_by_id(group)
  end)

  it('shows save and cancel key legend in the float footer', function()
    comment_input.open({ title = 'file.lua:1-1 (after)', on_submit = function() end })
    local footer = table.concat(vim.api.nvim_win_get_config(vim.api.nvim_get_current_win()).footer[1])
    assert.matches('<CR>', footer)
    assert.matches('save', footer)
    assert.matches('cancel', footer)
    vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
  end)

  it('submits with the configured key and cancels with q', function()
    local origin = vim.api.nvim_get_current_win()
    local submitted
    comment_input.open({ title = 'file.lua:1-1 (after)', on_submit = function(text) submitted = text end })
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'Save with keymap' })
    vim.cmd('stopinsert')
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-s>', true, false, true), 'xt', false)
    assert.equals('Save with keymap', submitted)
    assert.equals(origin, vim.api.nvim_get_current_win())

    local cancelled = false
    comment_input.open({ title = 'file.lua:1-1 (after)', on_submit = function() error('submitted cancelled comment') end,
      on_cancel = function() cancelled = true end })
    vim.cmd('stopinsert')
    vim.api.nvim_feedkeys('q', 'xt', false)
    assert.is_true(cancelled)
    assert.equals(origin, vim.api.nvim_get_current_win())
  end)

  it('submits with Enter in normal mode', function()
    local submitted
    comment_input.open({ title = 'file.lua:1-1 (after)', on_submit = function(text) submitted = text end })
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'Save with Enter' })
    vim.cmd('stopinsert')
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
    assert.equals('Save with Enter', submitted)
  end)

  it('submits with Ctrl-S while typing in insert mode', function()
    local submitted
    comment_input.open({ title = 'file.lua:1-1 (after)', on_submit = function(text) submitted = text end })
    vim.api.nvim_feedkeys('iType in insert mode', 'xt', false)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-s>', true, false, true), 'xt', false)
    assert.equals('Type in insert mode', submitted)
  end)
end)
