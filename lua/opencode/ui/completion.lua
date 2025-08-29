local M = {}

local completion_sources = {}

---@class CompletionItem
---@field label string Display label for the completion
---@field kind string Type of completion (file, subagent, command, etc.)
---@field detail string|nil Additional details about the item
---@field documentation string|nil Optional documentation for the item
---@field insert_text string|nil Text to insert (defaults to label)
---@field data any|nil Additional data for the completion
---@field source_name string|nil Name of the source that provided this item

---@class CompletionSource
---@field name string Name of the completion source
---@field complete fun(context: CompletionContext): CompletionItem[]
---@field resolve fun(item: CompletionItem): CompletionItem|nil Optional function to resolve additional data
---@field on_complete fun(item: CompletionItem): nil Optional function called when item is selected

---@class CompletionContext
---@field input string Current input text
---@field cursor_pos number Current cursor position
---@field line string Current line content
---@field prefix string Text before trigger symbol
---@field trigger_char string The character that triggered completion (e.g., '@')

function M.setup()
  local files_source = require('opencode.ui.completion.files')
  local subagents_source = require('opencode.ui.completion.subagents')
  local commands_source = require('opencode.ui.completion.commands')

  M.register_source(files_source.get_source())
  M.register_source(subagents_source.get_source())
  M.register_source(commands_source.get_source())

  local setup_success = false

  local engine = M.get_completion_engine()

  if engine == 'nvim-cmp' then
    local nvim_cmp_engine = require('opencode.ui.completion.engines.nvim_cmp')
    if nvim_cmp_engine.setup(completion_sources) then
      setup_success = true
      vim.notify('Opencode @ completion: nvim-cmp integration active', vim.log.levels.INFO)
    end
  elseif engine == 'blink' then
    local blink_cmp_engine = require('opencode.ui.completion.engines.blink_cmp')
    if blink_cmp_engine.setup(completion_sources) then
      setup_success = true
      vim.notify('Opencode @ completion: blink.cmp integration active', vim.log.levels.INFO)
    end
  elseif engine == 'vim_complete' then
    local vim_complete_engine = require('opencode.ui.completion.engines.vim_complete')
    vim_complete_engine.setup(completion_sources)
    setup_success = true
    vim.notify('Opencode @ completion: vim.fn.complete fallback active', vim.log.levels.INFO)
  end

  if not setup_success then
    vim.notify('Opencode: No completion engine available', vim.log.levels.WARN)
  end
end

---Register a completion source
---@param source CompletionSource
function M.register_source(source)
  table.insert(completion_sources, source)
end

---Get registered completion sources (for blink source module)
---@return CompletionSource[]
function M._get_sources()
  return completion_sources
end

---Call the on_complete method for a completion item
---@param item CompletionItem
function M._on_complete(item)
  if not item.source_name then
    return
  end

  -- Find the source that provided this item
  for _, source in ipairs(completion_sources) do
    if source.name == item.source_name and source.on_complete then
      source.on_complete(item)
      break
    end
  end
end

function M.get_completion_engine()
  local config = require('opencode.config').get()
  local engine = config.preferred_completion
  if not engine then
    local ok_cmp = pcall(require, 'cmp')
    local ok_blink = pcall(require, 'blink.cmp')
    if ok_blink then
      engine = 'blink'
    elseif ok_cmp then
      engine = 'nvim-cmp'
    else
      engine = 'vim_complete'
    end
  end
  return engine
end

function M.trigger_completion(trigger_char)
  return function()
    local engine = M.get_completion_engine()

    if engine == 'vim_complete' then
      require('opencode.ui.completion.engines.vim_complete').trigger(trigger_char)
    else
      vim.api.nvim_feedkeys(trigger_char, 'in', true)
    end
  end
end

return M
