local M = {}

---@param win_id integer
---@param highlight string
function M.update_highlights(win_id, highlight)
  local current = vim.api.nvim_get_option_value('winhighlight', { win = win_id })
  local parts = vim.split(current, ',')

  parts = vim.tbl_filter(function(part)
    return not part:match('^WinBar:') and not part:match('^WinBarNC:')
  end, parts)

  if not vim.tbl_contains(parts, 'Normal:OpencodeNormal') then
    table.insert(parts, 'Normal:OpencodeNormal')
  end

  table.insert(parts, 'WinBar:' .. highlight)
  table.insert(parts, 'WinBarNC:' .. highlight)

  vim.api.nvim_set_option_value('winhighlight', table.concat(parts, ','), { win = win_id })
end

return M
