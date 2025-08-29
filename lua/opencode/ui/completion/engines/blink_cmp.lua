local M = {}

local Source = {}
Source.__index = Source

function Source.new()
  local self = setmetatable({}, Source)
  return self
end

function Source:get_trigger_characters()
  local config = require('opencode.config').get()
  return { config.keymap.window.mention, config.keymap.window.slash_commands }
end

function Source:is_available()
  return vim.bo.filetype == 'opencode'
end

function Source:get_completions(ctx, callback)
  local completion = require('opencode.ui.completion')
  local completion_sources = completion._get_sources()

  local line = ctx.line
  local col = ctx.cursor[2] + 1
  local before_cursor = line:sub(1, col - 1)

  local trigger_chars = table.concat(vim.tbl_map(vim.pesc, self:get_trigger_characters()), '')
  local trigger_char, trigger_match = before_cursor:match('.*([' .. trigger_chars .. '])([%w_%-%.]*)')

  if not trigger_match then
    callback({ is_incomplete_forward = false, items = {} })
    return
  end

  local context = {
    input = trigger_match,
    cursor_pos = col,
    line = line,
    trigger_char = trigger_char,
  }

  -- Collect items from all sources
  local items = {}
  for _, completion_source in ipairs(completion_sources) do
    local source_items = completion_source.complete(context)
    for _, item in ipairs(source_items) do
      table.insert(items, {
        label = item.label,
        kind = 1, -- Text
        detail = item.detail,
        documentation = item.documentation,
        insertText = item.insert_text or item.label,
        data = {
          original_item = item, -- Store original item for on_complete
        },
      })
    end
  end

  callback({ is_incomplete_forward = true, items = items })
end

function Source:execute(ctx, item, callback, default_implementation)
  -- Handle the execution of the item
  default_implementation()

  -- Call our custom on_complete logic
  if item.data and item.data.original_item then
    local completion = require('opencode.ui.completion')
    completion._on_complete(item.data.original_item)
  end

  -- The callback MUST be called
  callback()
end

function M.setup(completion_sources)
  local ok, blink = pcall(require, 'blink.cmp')
  if not ok then
    return false
  end

  -- Register the source directly in this module
  blink.add_source_provider('opencode_mentions', {
    module = 'opencode.ui.completion.engines.blink_cmp',
  })

  blink.add_filetype_source('opencode', 'opencode_mentions')

  return true
end

-- Export the constructor function for blink.cmp
M.new = Source.new

return M
