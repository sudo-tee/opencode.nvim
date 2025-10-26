local M = {}

function M.setup()
  local is_light = vim.o.background == 'light'

  if is_light then
    vim.api.nvim_set_hl(0, 'OpencodeBorder', { fg = '#9E9E9E', default = true })
    vim.api.nvim_set_hl(0, 'OpencodeBackground', { link = 'Normal', default = true })
    vim.api.nvim_set_hl(0, 'OpencodeSessionDescription', { link = 'Comment', default = true })
    vim.api.nvim_set_hl(0, 'OpencodeMention', { link = 'Special', default = true })
    vim.api.nvim_set_hl(0, 'OpencodeToolBorder', { fg = '#B0BEC5', nocombine = true, default = true })
    vim.api.nvim_set_hl(0, 'OpencodeMessageRoleAssistant', { link = 'Special', default = true })
    vim.api.nvim_set_hl(0, 'OpencodeMessageRoleUser', { link = 'Question', default = true })
    vim.api.nvim_set_hl(0, 'OpencodeDiffAdd', { bg = '#E8F5E8', default = true })
    vim.api.nvim_set_hl(0, 'OpencodeDiffDelete', { bg = '#FFEBEE', default = true })
    vim.api.nvim_set_hl(0, 'OpencodeDiffAddText', { link = 'Added', default = true })
    vim.api.nvim_set_hl(0, 'OpencodeDiffDeleteText', { link = 'Removed', default = true })
    vim.api.nvim_set_hl(0, 'OpencodeRevertBorder', { bg = '#FF9E3B', default = true })
    vim.api.nvim_set_hl(0, 'OpencodeAgentPlan', { bg = '#2196F3', fg = '#FFFFFF', bold = true, default = true })
    vim.api.nvim_set_hl(0, 'OpencodeAgentBuild', { bg = '#757575', fg = '#FFFFFF', bold = true, default = true })
    vim.api.nvim_set_hl(0, 'OpencodeAgentCustom', { bg = '#90A4AE', fg = '#FFFFFF', bold = true, default = true })
    vim.api.nvim_set_hl(0, 'OpencodeContextualActions', { bg = '#90A4AE', fg = '#1976D2', bold = true, default = true })
    vim.api.nvim_set_hl(0, 'OpencodeInputLegend', { bg = '#757575', fg = '#424242', bold = false, default = true })
    vim.api.nvim_set_hl(0, 'OpencodeHint', { link = 'Comment', default = true })
    vim.api.nvim_set_hl(0, 'OpencodeGuardDenied', { fg = '#F44336', bold = true, default = true })
  else
    vim.api.nvim_set_hl(0, 'OpencodeBorder', { fg = '#616161', default = true })
    vim.api.nvim_set_hl(0, 'OpencodeBackground', { link = 'Normal', default = true })
    vim.api.nvim_set_hl(0, 'OpencodeSessionDescription', { link = 'Comment', default = true })
    vim.api.nvim_set_hl(0, 'OpencodeMention', { link = 'Special', default = true })
    vim.api.nvim_set_hl(0, 'OpencodeToolBorder', { fg = '#3b4261', nocombine = true, default = true })
    vim.api.nvim_set_hl(0, 'OpencodeRevertBorder', { bg = '#FF9E3B', default = true })
    vim.api.nvim_set_hl(0, 'OpencodeMessageRoleAssistant', { link = 'Added', default = true })
    vim.api.nvim_set_hl(0, 'OpencodeMessageRoleUser', { link = 'Question', default = true })
    vim.api.nvim_set_hl(0, 'OpencodeDiffAdd', { bg = '#2B3328', default = true })
    vim.api.nvim_set_hl(0, 'OpencodeDiffDelete', { bg = '#43242B', default = true })
    vim.api.nvim_set_hl(0, 'OpencodeDiffAddText', { link = 'Added', default = true })
    vim.api.nvim_set_hl(0, 'OpencodeDiffDeleteText', { link = 'Removed', default = true })
    vim.api.nvim_set_hl(0, 'OpencodeAgentPlan', { bg = '#61AFEF', fg = '#FFFFFF', bold = true, default = true })
    vim.api.nvim_set_hl(0, 'OpencodeAgentBuild', { bg = '#616161', fg = '#FFFFFF', bold = true, default = true })
    vim.api.nvim_set_hl(0, 'OpencodeAgentCustom', { bg = '#3b4261', fg = '#FFFFFF', bold = true, default = true })
    vim.api.nvim_set_hl(0, 'OpencodeContextualActions', { bg = '#3b4261', fg = '#61AFEF', bold = true, default = true })
    vim.api.nvim_set_hl(0, 'OpencodeInputLegend', { bg = '#616161', fg = '#CCCCCC', bold = false, default = true })
    vim.api.nvim_set_hl(0, 'OpencodeHint', { link = 'Comment', default = true })
    vim.api.nvim_set_hl(0, 'OpencodeGuardDenied', { fg = '#EF5350', bold = true, default = true })
  end
end

return M
