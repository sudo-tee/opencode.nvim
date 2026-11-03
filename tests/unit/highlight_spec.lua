local highlight = require('opencode.ui.highlight')

describe('opencode highlight groups', function()
  local name = 'OpencodeDialogOptionHover'

  after_each(function()
    pcall(vim.api.nvim_del_augroup_by_name, 'OpencodePluginHighlights')
    vim.cmd.colorscheme('default')
    vim.api.nvim_set_hl(0, name, {})
  end)

  it('restores highlights after a colorscheme change', function()
    highlight.setup()

    assert.is_not_nil(next(vim.api.nvim_get_hl(0, { name = name })))

    vim.cmd.colorscheme('habamax')

    assert.is_not_nil(next(vim.api.nvim_get_hl(0, { name = name })))
  end)

  it('preserves custom highlights', function()
    highlight.setup()
    vim.api.nvim_set_hl(0, name, { fg = '#123456' })

    vim.api.nvim_exec_autocmds('ColorScheme', {
      pattern = 'custom-theme',
    })

    assert.are.equal(0x123456, vim.api.nvim_get_hl(0, { name = name }).fg)
  end)

  it('registers only one ColorScheme handler', function()
    highlight.setup()
    highlight.setup()

    local autocmds = vim.api.nvim_get_autocmds({
      event = 'ColorScheme',
      group = 'OpencodePluginHighlights',
    })

    assert.are.equal(1, #autocmds)
  end)
end)
