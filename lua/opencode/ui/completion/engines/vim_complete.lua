local M = {}

local completion_active = false

function M.setup(completion_sources)
  vim.api.nvim_create_autocmd('FileType', {
    pattern = 'opencode',
    callback = function(args)
      local buf = args.buf
      vim.api.nvim_create_autocmd('TextChangedI', { buffer = buf, callback = M._update })
      vim.api.nvim_create_autocmd('CompleteDone', { buffer = buf, callback = M.on_complete })
    end,
  })

  M._completion_sources = completion_sources

  return true
end

function M._fake_feed_key(trigger_char)
  local cursor_pos = vim.api.nvim_win_get_cursor(0)
  local row = cursor_pos[1] - 1
  local col = cursor_pos[2]

  vim.api.nvim_buf_set_text(0, row, col, row, col, { trigger_char })
  vim.api.nvim_win_set_cursor(0, { row + 1, col + 1 })
end

function M._get_trigger(before_cursor)
  local config = require('opencode.config')
  local mention_key = config.get_key_for_function('input_window', 'mention')
  local slash_key = config.get_key_for_function('input_window', 'slash_commands')
  local triggers = {}
  if mention_key then
    table.insert(triggers, mention_key)
  end
  if slash_key then
    table.insert(triggers, slash_key)
  end
  local trigger_chars = table.concat(vim.tbl_map(vim.pesc, triggers), '')
  local trigger_char, trigger_match = before_cursor:match('.*([' .. trigger_chars .. '])([%w_%-%.]*)')
  return trigger_char, trigger_match
end

function M.trigger(trigger_char)
  M._fake_feed_key(trigger_char)

  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local before_cursor = line:sub(1, col)
  local _, trigger_match = M._get_trigger(before_cursor)

  if not trigger_match then
    return
  end

  completion_active = true
  M._update()
end

function M._update()
  if not completion_active then
    return
  end

  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local before_cursor = line:sub(1, col)
  local trigger_char, trigger_match = M._get_trigger(before_cursor)

  if not trigger_char then
    completion_active = false
    return
  end

  local context = {
    input = trigger_match,
    cursor_pos = col + 1,
    line = line,
    trigger_char = trigger_char,
  }

  local items = {}
  for _, source in ipairs(M._completion_sources or {}) do
    local source_items = source.complete(context)
    for _, item in ipairs(source_items) do
      if vim.startswith(item.insert_text or '', trigger_char) then
        item.insert_text = item.insert_text:sub(2)
      end
      table.insert(items, {
        word = item.insert_text,
        abbr = item.label,
        menu = source.name,
        kind = item.kind:sub(1, 1):upper(),
        user_data = item,
      })
    end
  end

  if #items > 0 then
    local start_col = before_cursor:find(vim.pesc(trigger_char) .. '[%w_%-%.]*$')
    if start_col then
      vim.fn.complete(start_col + 1, items)
    end
  else
    completion_active = false
  end
end

M.on_complete = function()
  local completed_item = vim.v.completed_item
  if completed_item and completed_item.word and completed_item.user_data then
    completion_active = false
    local completion = require('opencode.ui.completion')
    completion.on_complete(completed_item.user_data)
  end
end

return M
