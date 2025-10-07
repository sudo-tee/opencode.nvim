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
    local config = require('opencode.config').get()
    local keymap = require('opencode.keymap')
    return { keymap.extract_key(config.keymap.window.mention), keymap.extract_key(config.keymap.window.slash_commands) }
  end

  function source:is_available()
    return vim.bo.filetype == 'opencode'
  end

  function source:complete(params, callback)
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
    for i, completion_source in ipairs(completion_sources) do
      local source_items = completion_source.complete(context)
      for j, item in ipairs(source_items) do
        table.insert(items, {
          label = item.label,
          kind = item.kind == 'file' and cmp.lsp.CompletionItemKind.File or cmp.lsp.CompletionItemKind.Text,
          detail = item.detail,
          documentation = item.documentation,
          insertText = item.insert_text or item.label,
          sortText = string.format('%03d_%03d_%s', i, j, item.label),
          data = {
            original_item = item,
          },
        })
      end
    end

    callback({ items = items, isIncomplete = false })
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
