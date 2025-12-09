local Promise = require('opencode.promise')
local M = {}

function M.setup(completion_sources)
  local ok, cmp = pcall(require, 'cmp')
  if not ok then
    return false
  end
  local source = {}

  function source.new()
    return setmetatable({}, { __index = source })
  end

  function source:get_trigger_characters()
    local config = require('opencode.config')
    local mention_key = config.get_key_for_function('input_window', 'mention')
    local slash_key = config.get_key_for_function('input_window', 'slash_commands')
    local context_key = config.get_key_for_function('input_window', 'context_items')
    return {
      slash_key or '',
      mention_key or '',
      context_key or '',
    }
  end

  function source:is_available()
    return vim.bo.filetype == 'opencode'
  end

  function source:complete(params, callback)
    Promise.spawn(function()
      local line = params.context.cursor_line

      local col = params.context.cursor.col
      local before_cursor = line:sub(1, col - 1)

      local trigger_chars = table.concat(vim.tbl_map(vim.pesc, self:get_trigger_characters()), '')
      local trigger_char, trigger_match = before_cursor:match('.*([' .. trigger_chars .. '])([%w_%-%.]*)')

      if not trigger_match then
        callback({ items = {}, isIncomplete = false })
        return
      end

      local context = {
        input = trigger_match,
        cursor_pos = col,
        line = line,
        trigger_char = trigger_char,
      }

      local items = {}
      for _, completion_source in ipairs(completion_sources) do
        local source_items = completion_source.complete(context):await()
        for j, item in ipairs(source_items) do
          table.insert(items, {
            label = item.label,
            kind = 1,
            cmp = {
              kind_text = item.kind_icon,
            },
            kind_hl_group = item.kind_hl,
            detail = item.detail,
            documentation = item.documentation,
            insertText = item.insert_text or '',
            sortText = string.format(
              '%02d_%02d_%02d_%s',
              completion_source.priority or 999,
              item.priority or 999,
              j,
              item.label
            ),
            data = {
              original_item = item,
            },
          })
        end
      end

      callback({ items = items, isIncomplete = true })
    end)
  end

  cmp.register_source('opencode_mentions', source.new())

  local config = cmp.get_config()
  local sources = vim.deepcopy(config.sources or {})

  cmp.setup.filetype({ 'opencode' }, {
    sources = vim.list_extend(sources, {
      {
        name = 'opencode_mentions',
        keyword_length = 1,
        options = {},
      },
    }),
  })

  cmp.event:on('confirm_done', function(event)
    local entry = event and event.entry
    if entry and entry.source.name == 'opencode_mentions' then
      local item_data = entry:get_completion_item().data
      if item_data and item_data.original_item then
        local completion = require('opencode.ui.completion')
        completion.on_complete(item_data.original_item)
      end
    end
  end)

  return true
end

return M
