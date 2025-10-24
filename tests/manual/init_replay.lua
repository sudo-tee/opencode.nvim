local plugin_root = vim.fn.getcwd()

vim.notify(plugin_root)
vim.opt.runtimepath:append(plugin_root)

local plenary_path = plugin_root .. '/deps/plenary.nvim'

-- Check if plenary exists, if not, clone it
if vim.fn.isdirectory(plenary_path) ~= 1 then
  -- Create deps directory if it doesn't exist
  if vim.fn.isdirectory(plugin_root .. '/deps') ~= 1 then
    vim.fn.mkdir(plugin_root .. '/deps', 'p')
  end

  print('Cloning plenary.nvim for testing...')
  local clone_cmd = 'git clone --depth 1 https://github.com/nvim-lua/plenary.nvim.git ' .. plenary_path
  vim.fn.system(clone_cmd)
end

vim.opt.runtimepath:append(plenary_path)

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
