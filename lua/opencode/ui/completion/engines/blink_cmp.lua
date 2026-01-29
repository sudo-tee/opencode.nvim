local Promise = require('opencode.promise')
local state = require('opencode.state')
local CompletionEngine = require('opencode.ui.completion.engines.base')

---@class BlinkCmpEngine : CompletionEngine
local BlinkCmpEngine = setmetatable({}, { __index = CompletionEngine })
BlinkCmpEngine.__index = BlinkCmpEngine

---Create a new blink-cmp completion engine
---@return BlinkCmpEngine
function BlinkCmpEngine.new()
  local self = CompletionEngine.new('blink_cmp')
  return setmetatable(self, BlinkCmpEngine)
end

---Check if blink-cmp is available
---@return boolean
function BlinkCmpEngine:is_available()
  return pcall(require, 'blink.cmp') and CompletionEngine.is_available()
end

---Setup blink-cmp completion engine
---@param completion_sources table[]
---@return boolean
function BlinkCmpEngine:setup(completion_sources)
  local ok, blink = pcall(require, 'blink.cmp')
  if not ok then
    return false
  end

  CompletionEngine.setup(self, completion_sources)

  blink.add_source_provider('opencode_mentions', {
    module = 'opencode.ui.completion.engines.blink_cmp',
    async = true,
  })

  vim.api.nvim_create_autocmd('User', {
    group = vim.api.nvim_create_augroup('OpencodeBlinkCmp', { clear = true }),
    pattern = 'BlinkCmpMenuOpen',
    callback = function()
      local current_buf = vim.api.nvim_get_current_buf()
      local input_buf = vim.tbl_get(state, 'windows', 'input_buf')
      if not state.windows or current_buf ~= input_buf then
        return
      end

      local blink = require('blink.cmp')
      local ctx = blink.get_context()
      local triggers = CompletionEngine.get_trigger_characters()

      -- blink has a tendency to show other providers even when we want only our own.
      local should_override = (
        ctx.trigger.initial_kind == 'trigger_character' and vim.tbl_contains(triggers, ctx.trigger.character)
      ) or (ctx.trigger.initial_kind == 'keyword' and vim.tbl_contains(triggers, ctx.line:sub(1, 1)))

      if should_override then
        blink.show({
          providers = { 'opencode_mentions' },
          trigger_character = ctx.trigger.character,
        })
      end
    end,
  })
  return true
end

---Check if blink-cmp completion menu is visible
---@return boolean
function BlinkCmpEngine:is_visible()
  local blink = require('blink.cmp')
  return blink.is_visible()
end

---Trigger completion manually for blink-cmp
---@param trigger_char string
function BlinkCmpEngine:trigger(trigger_char)
  local blink = require('blink.cmp')

  vim.api.nvim_feedkeys(trigger_char, 'in', true)
  if blink.is_visible() then
    blink.hide()
  end

  blink.show({
    providers = { 'opencode_mentions' },
    trigger_character = trigger_char,
  })
end

function BlinkCmpEngine:hide()
  require('blink.cmp').hide()
end

-- Source implementation for blink-cmp provider (when this module is loaded by blink.cmp)
local Source = {}
Source.__index = Source

function Source.new()
  local self = setmetatable({}, Source)
  return self
end

function Source:get_trigger_characters()
  return CompletionEngine.get_trigger_characters()
end

function Source:enabled()
  return CompletionEngine.is_available()
end

function Source:get_completions(ctx, callback)
  Promise.spawn(function()
    local completion = require('opencode.ui.completion')
    local completion_sources = completion.get_sources()

    local line = ctx.line
    local col = ctx.cursor[2] + 1
    local before_cursor = line:sub(1, col - 1)

    local trigger_char, trigger_match = CompletionEngine.parse_trigger(self, before_cursor)

    if not trigger_match then
      callback({ is_incomplete_forward = false, items = {} })
      return
    end

    ---@type CompletionContext
    local context = {
      input = trigger_match,
      cursor_pos = col,
      line = line,
      trigger_char = trigger_char or '',
    }

    local items = {}
    for _, source in ipairs(completion_sources) do
      local source_items = source.complete(context):await()
      for i, item in ipairs(source_items) do
        local insert_text = item.insert_text or item.label
        table.insert(items, {
          label = item.label,
          kind = item.kind,
          kind_icon = item.kind_icon,
          kind_hl = item.kind_hl,
          detail = item.detail,
          documentation = item.documentation,
          filterText = item.filter_text or item.label,
          insertText = insert_text,
          sortText = string.format('%02d_%02d_%02d_%s', source.priority or 999, item.priority or 999, i, item.label),
          score_offset = -(source.priority or 999) * 1000 + (item.priority or 999),
          data = {
            original_item = item,
          },
        })
      end
    end

    callback({ is_incomplete_forward = true, is_incomplete_backward = true, items = items })
  end)
end

function Source:execute(_, item, callback, default_implementation)
  default_implementation()

  if item.data and item.data.original_item then
    CompletionEngine.on_complete(self, item.data.original_item)
  end

  callback()
end

-- Export module with dual interface:
-- - For our engine system: use BlinkCmpEngine methods
-- - For blink.cmp provider system: override 'new' to return Source instance
local M = BlinkCmpEngine

-- Save the engine constructor before overriding
M.create = BlinkCmpEngine.new

-- Override 'new' for blink.cmp compatibility (when blink loads this as a source)
M.new = Source.new

return M
