local M = {}

-- Setup nvim-cmp integration
function M.setup(completion_sources)
  local ok, cmp = pcall(require, 'cmp')
  if not ok then
    return false
  end

  local source = {}

  function source:get_trigger_characters()
    local config = require('opencode.config').get()
    return { config.keymap.window.mention, config.keymap.window.slash_commands }
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

    -- Collect items from all sources
    local items = {}
    for _, completion_source in ipairs(completion_sources) do
      local source_items = completion_source.complete(context)
      for _, item in ipairs(source_items) do
        table.insert(items, {
          label = item.label,
          kind = cmp.lsp.CompletionItemKind.Text,
          detail = item.detail,
          documentation = item.documentation,
          insertText = item.insert_text or item.label,
          data = {
            original_item = item, -- Store original item for on_complete
          },
        })
      end
    end

    callback({ items = items, isIncomplete = false })
  end

  -- Register the source
  cmp.register_source('opencode_mentions', source)

  -- Add to existing config
  local config = cmp.get_config()
  local sources = vim.deepcopy(config.sources or {})

  -- Add our source if not already present
  local has_source = false
  for _, src in ipairs(sources) do
    if src.name == 'opencode_mentions' then
      has_source = true
      break
    end
  end

  if not has_source then
    table.insert(sources, 1, { name = 'opencode_mentions' })
    cmp.setup.buffer({ sources = sources })
  end

  cmp.setup.buffer({
    sources = sources,
    confirmation = {
      completeopt = 'menu,menuone,noinsert',
    },
  })

  vim.api.nvim_create_autocmd('User', {
    pattern = 'CmpConfirmDone',
    callback = function(event)
      local entry = event.data and event.data.entry
      if entry and entry.source.name == 'opencode_mentions' then
        local item_data = entry:get_completion_item().data
        if item_data and item_data.original_item then
          -- Call the on_complete method
          local completion = require('opencode.ui.completion')
          completion.on_complete(item_data.original_item)
        end
      end
    end,
  })

  return true
end

return M
