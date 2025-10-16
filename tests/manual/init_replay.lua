local plugin_root = vim.fn.expand('$PWD')
vim.opt.runtimepath:append(plugin_root)

local plenary_path = plugin_root .. '/deps/plenary.nvim'
if vim.fn.isdirectory(plenary_path) == 1 then
  vim.opt.runtimepath:append(plenary_path)
end

vim.o.laststatus = 3
vim.o.termguicolors = true
vim.g.mapleader = ' '
vim.opt.clipboard:append('unnamedplus')

-- for testing contextual_actions
vim.o.updatetime = 250

vim.g.opencode_config = {
  ui = {
    default_mode = 'build',
  },
}

require('opencode').setup()

require('tests.manual.renderer_replay').start()
