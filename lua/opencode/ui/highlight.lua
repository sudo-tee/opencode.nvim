local M = {}

function M.setup()
  vim.api.nvim_set_hl(0, 'OpencodeBorder', { fg = '#616161' })
  vim.api.nvim_set_hl(0, 'OpencodeBackground', { link = "Normal" })
  vim.api.nvim_set_hl(0, 'OpencodeSessionDescription', { link = "Comment" })
  vim.api.nvim_set_hl(0, "OpencodeMention", { link = "Special" })
end

return M
