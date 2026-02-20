if vim.b.did_ftplugin then
  return
end
vim.b.did_ftplugin = true
-- Auto-attach opencode LSP to opencode input buffers

-- This provides completion for files, subagents, commands, and context items
-- Works with any LSP-compatible completion plugin (blink.cmp, nvim-cmp, etc.)

local bufnr = vim.api.nvim_get_current_buf()

-- Start the in-process LSP server
local ok_lsp, opencode_ls = pcall(require, 'opencode.lsp.opencode_ls')
if not ok_lsp then
  vim.notify('Failed to load opencode LSP server: ' .. tostring(opencode_ls), vim.log.levels.WARN)
  return
end

local client_id = opencode_ls.start(bufnr)

if client_id then
  local completion = require('opencode.ui.completion')
  -- track insert start state
  vim.api.nvim_create_autocmd('InsertEnter', {
    buffer = bufnr,
    callback = function()
      completion.on_insert_enter()
    end,
  })

  vim.api.nvim_create_autocmd('TextChangedI', {
    buffer = bufnr,
    callback = function(e)
      completion.on_text_changed()
    end,
  })
end
