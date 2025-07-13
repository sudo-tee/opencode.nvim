local api = require('opencode.api')
-- UI utility functions
local M = {}

-- Navigate through prompt history with consideration for multi-line input
-- Only triggers history navigation at text boundaries when using arrow keys
function M.navigate_history(key, direction)
  return function()
    local is_arrow_key = key == '<up>' or key == '<down>'
    local is_prev = direction == 'prev'
    local history_fn = is_prev and api.prev_history or api.next_history

    local current_line = vim.api.nvim_win_get_cursor(0)[1]
    local at_boundary = is_prev and current_line <= 1 or not is_prev and current_line >= vim.api.nvim_buf_line_count(0)

    if at_boundary or not is_arrow_key then
      return history_fn()
    end

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), 'n', false)
  end
end

return M
