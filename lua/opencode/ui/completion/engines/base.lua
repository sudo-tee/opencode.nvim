local Promise = require('opencode.promise')

---@class CompletionEngine
---@field name string The name identifier of the completion engine
---@field _completion_sources table[]|nil Internal array of registered completion sources
---
--- Base class for all completion engines in opencode.nvim
--- Provides a common interface and shared functionality for different completion systems
--- like nvim-cmp, blink.cmp, and vim's built-in completion.
---
--- Child classes should override:
--- - setup(completion_sources): Initialize the engine with sources
--- - trigger(trigger_char): Handle manual completion triggering
--- - is_available(): Check if the engine can be used in current context
---
--- Common methods provided:
--- - get_trigger_characters(): Returns configured trigger characters
--- - parse_trigger(text): Parses trigger characters from text
--- - get_completion_items(context): Gets formatted completion items
--- - on_complete(item): Handles completion selection
local CompletionEngine = {}
CompletionEngine.__index = CompletionEngine

---Create a new completion engine instance
---@param name string The identifier name for this engine (e.g., 'nvim_cmp', 'blink_cmp')
---@return CompletionEngine The new engine instance
function CompletionEngine.new(name)
  local self = setmetatable({}, CompletionEngine)
  self.name = name
  self._completion_sources = nil
  return self
end

---Get trigger characters from config
---@return string[]
function CompletionEngine:get_trigger_characters()
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

---Check if the completion engine is available for use
---Default implementation checks if current buffer filetype is 'opencode'
---Child classes can override this to add engine-specific availability checks
---@return boolean true if the engine can be used in the current context
function CompletionEngine:is_available()
  return vim.bo.filetype == 'opencode'
end

---Parse trigger characters from text before cursor
---Identifies trigger characters and extracts the completion query text
---@param before_cursor string Text from line start to cursor position
---@return string|nil trigger_char The trigger character found (e.g., '@', '/')
---@return string|nil trigger_match The text after the trigger character
function CompletionEngine:parse_trigger(before_cursor)
  local triggers = self:get_trigger_characters()
  local trigger_chars = table.concat(vim.tbl_map(vim.pesc, triggers), '')
  local trigger_char, trigger_match = before_cursor:match('.*([' .. trigger_chars .. '])([%w_%-%.]*)')
  return trigger_char, trigger_match
end

---Get completion items from all registered sources
---Queries all completion sources and formats their responses into a unified structure
---@param context table Completion context containing input, cursor_pos, line, trigger_char
---@return table[] Array of wrapped completion items with metadata
CompletionEngine.get_completion_items = Promise.async(function(self, context)
  local items = {}
  for _, source in ipairs(self._completion_sources or {}) do
    local source_items = source.complete(context):await()
    for i, item in ipairs(source_items) do
      local source_priority = source.priority or 999
      local item_priority = item.priority or 999
      table.insert(items, {
        original_item = item,
        source_priority = source_priority,
        item_priority = item_priority,
        index = i,
        source_name = source.name,
      })
    end
  end
  return items
end)

---Setup the completion engine with completion sources
---Base implementation stores sources. Child classes should call this via super
---and then perform engine-specific initialization
---@param completion_sources table[] Array of completion source objects
---@return boolean success true if setup was successful
function CompletionEngine:setup(completion_sources)
  self._completion_sources = completion_sources
  return true
end

---Trigger completion manually for a specific character
---Child classes should override this to implement engine-specific triggering
---Default implementation does nothing
---@param trigger_char string The character that triggered completion
function CompletionEngine:trigger(trigger_char)
  -- Default implementation does nothing
end

---Handle completion item selection
---Called when a completion item is selected by the user
---Delegates to the completion module's on_complete handler
---@param original_item table The original completion item that was selected
function CompletionEngine:on_complete(original_item)
  local completion = require('opencode.ui.completion')
  completion.on_complete(original_item)
end

return CompletionEngine
