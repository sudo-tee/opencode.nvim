-- UI utility functions
local M = {}

-- Navigate through prompt history with consideration for multi-line input
-- Only triggers history navigation at text boundaries when using arrow keys
function M.navigate_history(direction, key, prev_history_fn, next_history_fn)
  return function()
    -- Check if using arrow keys
    local is_arrow_key = key == '<up>' or key == '<down>'

    if is_arrow_key then
      -- Get cursor position info
      local cursor_pos = vim.api.nvim_win_get_cursor(0)
      local current_line = cursor_pos[1]
      local line_count = vim.api.nvim_buf_line_count(0)

      -- Navigate history only at boundaries
      if (direction == 'prev' and current_line <= 1) or
          (direction == 'next' and current_line >= line_count) then
        if direction == 'prev' then prev_history_fn() else next_history_fn() end
      else
        -- Otherwise use normal navigation
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), 'n', false)
      end
    else
      -- Not arrow keys, always use history navigation
      if direction == 'prev' then prev_history_fn() else next_history_fn() end
    end
  end
end

return M
