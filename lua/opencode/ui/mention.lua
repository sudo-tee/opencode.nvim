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
      ---@cast mention_start integer

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

---Apply frozen byte ranges from normalized protocol Content.
---@param output Output Output object to write to
---@param text string The full text content
---@param mentions table[] Mention data with zero-based UTF-8 byte offsets
---@param start_line number The starting line index in the output (1-indexed)
function M.highlight_mentions_in_output(output, text, mentions, start_line)
  for _, mention in ipairs(mentions) do
    local byte_start = mention.start_byte
    local byte_end = mention.end_byte
    local value = mention.text

    if type(byte_start) ~= 'number' or type(byte_end) ~= 'number' or type(value) ~= 'string' then
      goto continue
    end

    local byte_count = 0

    for i, line in ipairs(vim.split(text, '\n')) do
      local line_start = byte_count
      local line_end = byte_count + #line

      if byte_start == 0 and string.sub(text, 1, 1) ~= '@' then
        local start_pos, end_pos = string.find(line, value, 1, true)

        if start_pos then
          output:add_extmark(start_line + i - 1, {
            start_col = start_pos - 1,
            end_col = end_pos,
            hl_group = 'OpencodeMention',
            priority = 1000,
          })
          break
        end
      else
        if byte_start >= line_start and byte_start < line_end then
          local col_start = byte_start - line_start
          local col_end = math.min(byte_end - line_start, #line)

          output:add_extmark(start_line + i - 1, {
            start_col = col_start,
            end_col = col_end,
            hl_group = 'OpencodeMention',
            priority = 1000,
          } --[[@as OutputExtmark]])
          break
        end

        byte_count = line_end + 1
      end
    end
    ::continue::
  end
end

local function insert_mention(windows, row, col, name)
  local current_line = vim.api.nvim_buf_get_lines(windows.input_buf, row - 1, row, false)[1]

  if not current_line then
    return
  end

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
      if not windows or not windows.input_win or not name then
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
    if name:find('^pasted_image_') then
      local restored_path = require('opencode.image_handler').restore_img_path(name)
      if restored_path then
        require('opencode.context').add_file(restored_path)
      end
    end
  end)
end

return M
