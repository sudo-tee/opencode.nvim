local M = {}

function M.setup()
  vim.api.nvim_set_hl(0, 'OpencodeBorder', { fg = '#616161' })
  vim.api.nvim_set_hl(0, 'OpencodeBackground', { link = 'Normal' })
  vim.api.nvim_set_hl(0, 'OpencodeSessionDescription', { link = 'Comment' })
  vim.api.nvim_set_hl(0, 'OpencodeMention', { link = 'Special' })
  vim.api.nvim_set_hl(0, 'OpencodeToolBorder', { fg = '#3b4261', nocombine = true })
  vim.api.nvim_set_hl(0, 'OpencodeMessageRoleAssistant', { link = 'Added' })
  vim.api.nvim_set_hl(0, 'OpencodeMessageRoleUser', { link = 'Question' })
  vim.api.nvim_set_hl(0, 'OpencodeDiffAdd', { bg = '#2B3328' })
  vim.api.nvim_set_hl(0, 'OpencodeDiffDelete', { bg = '#43242B' })
  vim.api.nvim_set_hl(0, 'OpencodeModePlan', { bg = '#61AFEF', fg = '#FFFFFF', bold = true })
  vim.api.nvim_set_hl(0, 'OpencodeModeBuild', { bg = '#616161', fg = '#FFFFFF', bold = true })
  vim.api.nvim_set_hl(0, 'OpencodeModeCustom', { bg = '#3b4261', fg = '#FFFFFF', bold = true })
  vim.api.nvim_set_hl(0, 'OpencodeContextualActions', { bg = '#3b4261', fg = '#61AFEF', bold = true })
end

return M
