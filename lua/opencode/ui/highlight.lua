local M = {}

function M.setup()
  vim.api.nvim_set_hl(0, 'OpencodeBorder', { fg = '#616161', default = true })
  vim.api.nvim_set_hl(0, 'OpencodeBackground', { link = 'Normal', default = true })
  vim.api.nvim_set_hl(0, 'OpencodeSessionDescription', { link = 'Comment', default = true })
  vim.api.nvim_set_hl(0, 'OpencodeMention', { link = 'Special', default = true })
  vim.api.nvim_set_hl(0, 'OpencodeToolBorder', { fg = '#3b4261', nocombine = true, default = true })
  vim.api.nvim_set_hl(0, 'OpencodeMessageRoleAssistant', { link = 'Added', default = true })
  vim.api.nvim_set_hl(0, 'OpencodeMessageRoleUser', { link = 'Question', default = true })
  vim.api.nvim_set_hl(0, 'OpencodeDiffAdd', { bg = '#2B3328', default = true })
  vim.api.nvim_set_hl(0, 'OpencodeDiffDelete', { bg = '#43242B', default = true })
  vim.api.nvim_set_hl(0, 'OpencodeAgentPlan', { bg = '#61AFEF', fg = '#FFFFFF', bold = true, default = true })
  vim.api.nvim_set_hl(0, 'OpencodeAgentBuild', { bg = '#616161', fg = '#FFFFFF', bold = true, default = true })
  vim.api.nvim_set_hl(0, 'OpencodeAgentCustom', { bg = '#3b4261', fg = '#FFFFFF', bold = true, default = true })
  vim.api.nvim_set_hl(0, 'OpencodeContextualActions', { bg = '#3b4261', fg = '#61AFEF', bold = true, default = true })
  vim.api.nvim_set_hl(0, 'OpencodeInputLegend', { bg = '#616161', fg = '#CCCCCC', bold = false, default = true })
end

return M
