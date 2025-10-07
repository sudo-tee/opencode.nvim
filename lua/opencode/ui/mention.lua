local M = {}

local mentions_namespace = vim.api.nvim_create_namespace('OpencodeMentions')

function M.highlight_all_mentions(buf, callback)
  -- Pattern for mentions
  local mention_pattern = '@[%w_%-%./][%w_%-%./]*'

  -- Clear existing extmarks
  pcall(vim.api.nvim_buf_clear_namespace, buf, mentions_namespace, 0, -1)

  -- Get all lines in buffer
  local ok_lines, lines = pcall(vim.api.nvim_buf_get_lines, buf, 0, -1, false)
  if not ok_lines then
    return
  end

  for row, line in ipairs(lines) do
    local start_idx = 1
    -- Find all mentions in the line
    while true do
      local mention_start, mention_end = line:find(mention_pattern, start_idx)
      if not mention_start then
        break
      end

      if callback then
        callback(line:sub(mention_start + 1, mention_end), row, mention_start, mention_end)
      end

      -- Add extmark for this mention
      vim.api.nvim_buf_set_extmark(buf, mentions_namespace, row - 1, mention_start - 1, {
        end_col = mention_end,
        hl_group = 'OpencodeMention',
      })

      -- Move to search for the next mention
      start_idx = mention_end + 1
    end
  end
end

local function insert_mention(windows, row, col, name)
  local current_line = vim.api.nvim_buf_get_lines(windows.input_buf, row - 1, row, false)[1]

  local insert_name = '@' .. name .. ' '

  local new_line = current_line:sub(1, col) .. insert_name .. current_line:sub(col + 2)
  vim.api.nvim_buf_set_lines(windows.input_buf, row - 1, row, false, { new_line })

  M.highlight_all_mentions(windows.input_buf)

  vim.cmd('startinsert')
  vim.api.nvim_set_current_win(windows.input_win)
  vim.api.nvim_win_set_cursor(windows.input_win, { row, col + 1 + #insert_name + 1 })
end

function M.mention(get_name)
  local windows = require('opencode.state').windows

  get_name(function(name)
    vim.schedule(function()
      if not windows or not name then
        return
      end
      local cursor_pos = vim.api.nvim_win_get_cursor(windows.input_win)
      local row, col = cursor_pos[1], cursor_pos[2]
      insert_mention(windows, row, col, name)
    end)
  end)
end

function M.restore_mentions(buf)
  local context = require('opencode.context')

  context.clear_subagents()
  context.clear_files()

  M.highlight_all_mentions(buf, function(name)
    local agents = require('opencode.config_file').get_subagents()

    if vim.tbl_contains(agents, name) then
      require('opencode.context').add_subagent(name)
      return
    end

    if vim.fn.filereadable(name) == 1 then
      require('opencode.context').add_file(name)
      return
    end
  end)
end

return M
