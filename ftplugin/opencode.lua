if vim.b.did_ftplugin then
  return
end
vim.b.did_ftplugin = true
-- This provides completion for files, subagents, commands, and context items
-- Works with any LSP-compatible completion plugin (blink.cmp, nvim-cmp, etc.)

local bufnr = vim.api.nvim_get_current_buf()

local opencode_ls = require('opencode.lsp.opencode_ls')
local client_id = opencode_ls.start(bufnr)
local completion = require('opencode.ui.completion')
if client_id and not completion.has_completion_engine() then
  pcall(function()
    vim.bo.completeopt = 'menu,menuone,noselect,fuzzy'
    vim.lsp.completion.enable(true, client_id, bufnr, { autotrigger = true })
  end)
end
