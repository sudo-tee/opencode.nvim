local Promise = require('opencode.promise')
local CompletionEngine = require('opencode.ui.completion.engines.base')

---@class VimCompleteEngine : CompletionEngine
local VimCompleteEngine = setmetatable({}, { __index = CompletionEngine })
VimCompleteEngine.__index = VimCompleteEngine

local completion_active = false

---Create a new vim completion engine
---@return VimCompleteEngine
function VimCompleteEngine.new()
  local self = CompletionEngine.new('vim_complete')
  return setmetatable(self, VimCompleteEngine)
end

---Setup vim completion engine
---@param completion_sources table[]
---@return boolean
function VimCompleteEngine:setup(completion_sources)
  -- Call parent setup
  CompletionEngine.setup(self, completion_sources)

  local group = vim.api.nvim_create_augroup('OpencodeVimComplete', { clear = true })
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'opencode',
    callback = function(args)
      local buf = args.buf
      vim.api.nvim_create_autocmd('TextChangedI', {
        buffer = buf,
        callback = function()
          self:_update()
        end,
      })
      vim.api.nvim_create_autocmd('CompleteDone', {
        buffer = buf,
        callback = function()
          self:_on_complete_done()
        end,
      })
    end,
  })

  return true
end

---Check if vim completion menu is visible
---@return boolean
function VimCompleteEngine:is_visible()
  return vim.fn.pumvisible() == 1
end

---Trigger completion manually for vim
---@param trigger_char string
function VimCompleteEngine:trigger(trigger_char)
  self:_fake_feed_key(trigger_char)

  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local before_cursor = line:sub(1, col)
  local _, trigger_match = self:parse_trigger(before_cursor)

  if not trigger_match then
    return
  end

  completion_active = true
  self:_update()
end

---Insert trigger character at cursor position
---@param trigger_char string
function VimCompleteEngine:_fake_feed_key(trigger_char)
  local cursor_pos = vim.api.nvim_win_get_cursor(0)
  local row = cursor_pos[1] - 1
  local col = cursor_pos[2]

  vim.api.nvim_buf_set_text(0, row, col, row, col, { trigger_char })
  vim.api.nvim_win_set_cursor(0, { row + 1, col + 1 })
end

---Update completion items based on current cursor position
function VimCompleteEngine:_update()
  Promise.spawn(function()
    if not completion_active then
      return
    end

    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local before_cursor = line:sub(1, col)
    local trigger_char, trigger_match = self:parse_trigger(before_cursor)

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

    local wrapped_items = self:get_completion_items(context):await()
    local items = {}

    for _, wrapped_item in ipairs(wrapped_items) do
      local item = wrapped_item.original_item
      local insert_text = item.insert_text or ''

      -- Remove trigger character if it's part of the insert text
      if vim.startswith(insert_text, trigger_char) then
        insert_text = insert_text:sub(2)
      end

      table.insert(items, {
        word = #insert_text > 0 and insert_text or item.label,
        abbr = (item.kind_icon or '') .. item.label,
        menu = wrapped_item.source_name,
        kind = item.kind:sub(1, 1):upper(),
        user_data = item,
        _sort_text = string.format(
          '%02d_%02d_%02d_%s',
          wrapped_item.source_priority,
          wrapped_item.item_priority,
          wrapped_item.index,
          item.label
        ),
      })
    end

    table.sort(items, function(a, b)
      return a._sort_text < b._sort_text
    end)

    if #items > 0 then
      local start_col = before_cursor:find(vim.pesc(trigger_char) .. '[%w_%-%.]*$')
      if start_col then
        vim.fn.complete(start_col + 1, items)
      end
    else
      completion_active = false
    end
  end)
end

---Handle completion selection
function VimCompleteEngine:_on_complete_done()
  local completed_item = vim.v.completed_item
  if completed_item and completed_item.word and completed_item.user_data then
    completion_active = false
    self:on_complete(completed_item.user_data)
  end
end

return VimCompleteEngine

