local M = {}

function M.setup()
  vim.api.nvim_set_hl(0, 'OpencodeBorder', { fg = '#616161' })
  vim.api.nvim_set_hl(0, 'OpencodeBackground', { link = 'Normal' })
  vim.api.nvim_set_hl(0, 'OpencodeSessionDescription', { link = 'Comment' })
  vim.api.nvim_set_hl(0, 'OpencodeMention', { link = 'Special' })
  vim.api.nvim_set_hl(0, 'OpencodeToolBorder', { fg = '#3b4261', nocombine = true })
  vim.api.nvim_set_hl(0, 'OpencodeMessageRoleAssistant', { link = 'Added' })
  vim.api.nvim_set_hl(0, 'OpencodeMessageRoleUser', { link = 'Question' })
end

return M
