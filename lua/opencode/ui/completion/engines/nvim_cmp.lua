local Promise = require('opencode.promise')
local CompletionEngine = require('opencode.ui.completion.engines.base')

---@class NvimCmpEngine : CompletionEngine
local NvimCmpEngine = setmetatable({}, { __index = CompletionEngine })
NvimCmpEngine.__index = NvimCmpEngine

---Create a new nvim-cmp completion engine
---@return NvimCmpEngine
function NvimCmpEngine.new()
  local self = CompletionEngine.new('nvim_cmp')
  return setmetatable(self, NvimCmpEngine)
end

---Check if nvim-cmp is available
---@return boolean
function NvimCmpEngine:is_available()
  local ok = pcall(require, 'cmp')
  return ok and CompletionEngine.is_available()
end

---Setup nvim-cmp completion engine
---@param completion_sources table[]
---@return boolean
function NvimCmpEngine:setup(completion_sources)
  local ok, cmp = pcall(require, 'cmp')
  if not ok then
    return false
  end

  CompletionEngine.setup(self, completion_sources)

  local engine = self
  local source = {}

  function source.new()
    return setmetatable({}, { __index = source })
  end

  function source:get_trigger_characters()
    return engine:get_trigger_characters()
  end

  function source:is_available()
    return engine:is_available()
  end

  function source:complete(params, callback)
    Promise.spawn(function()
      local line = params.context.cursor_line
      local col = params.context.cursor.col
      local before_cursor = line:sub(1, col - 1)

      local trigger_char, trigger_match = engine:parse_trigger(before_cursor)

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

      local wrapped_items = engine:get_completion_items(context):await()
      local items = {}

      for _, wrapped_item in ipairs(wrapped_items) do
        local item = wrapped_item.original_item
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
            wrapped_item.source_priority,
            wrapped_item.item_priority,
            wrapped_item.index,
            item.label
          ),
          data = {
            original_item = item,
          },
        })
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
        engine:on_complete(item_data.original_item)
      end
    end
  end)

  return true
end

---Trigger completion manually for nvim-cmp
---@param trigger_char string
function NvimCmpEngine:trigger(trigger_char)
  vim.api.nvim_feedkeys(trigger_char, 'in', true)
  local cmp = require('cmp')
  if cmp.visible() then
    cmp.close()
  end
  cmp.complete()
end

return NvimCmpEngine
