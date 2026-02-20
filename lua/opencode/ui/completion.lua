local M = {
  ---@type CompletionSource[]
  _sources = {},
}

function M.setup()
  local files_source = require('opencode.ui.completion.files')
  local subagents_source = require('opencode.ui.completion.subagents')
  local commands_source = require('opencode.ui.completion.commands')
  local context_source = require('opencode.ui.completion.context')

  M.register_source(files_source.get_source())
  M.register_source(subagents_source.get_source())
  M.register_source(commands_source.get_source())
  M.register_source(context_source.get_source())

  table.sort(M._sources, function(a, b)
    return (a.priority or 0) > (b.priority or 0)
  end)
end

function M.get_trigger_characters()
  local triggers = {}
  for _, source in ipairs(M._sources) do
    if source.get_trigger_character then
      table.insert(triggers, source.get_trigger_character())
    end
  end
  return triggers
end

---Register a completion source
---@param source CompletionSource
function M.register_source(source)
  table.insert(M._sources, source)
end

---@return CompletionSource[]
function M.get_sources()
  return M._sources
end

---@param name string
---@return CompletionSource?
function M.get_source_by_name(name)
  for _, source in ipairs(M._sources) do
    if source.name == name then
      return source
    end
  end
  return nil
end

---Call the on_completion_done method for a completion item
---@param item CompletionItem
function M.on_completion_done(item)
  if not item.source_name then
    return
  end

  for _, source in ipairs(M._sources) do
    if source.name == item.source_name and source.on_complete then
      source.on_complete(item)
      break
    end
  end
end

--- NOTE: Quirks and utilities for completion engines
--- Ideally, these should be avoided and instead completion sources should adapt to the capabilities of the engine. But in practice, some quirks are unavoidable.

--- This makes the completion UX much better with aligned icons and proper highlights
function M.supports_kind_icons()
  local blink_ok, blink = pcall(require, 'blink.cmp')
  return blink_ok
end

--- Returns true when a float-based completion engine (blink.cmp, nvim-cmp, coc)
--- is available. Engines that use the native PUM (mini.completion, vim built-in)
function M.has_completion_engine()
  local blink_ok, blink = pcall(require, 'blink.cmp')
  if blink_ok then
    return true
  end

  local cmp_ok, cmp = pcall(require, 'cmp')
  if cmp_ok then
    return true
  end

  local mini_ok, mini = pcall(require, 'mini.completion')
  if mini_ok then
    return true
  end

  if vim.fn.exists('*coc#pum#visible') == 1 then
    return true
  end

  return false
end

--- Check if the completion menu is currently visible.
--- Engines that use the native PUM (mini.completion, vim built-in) are
--- covered by the pumvisible() fallback at the end.
function M.is_completion_visible()
  local blink_ok, blink = pcall(require, 'blink.cmp')
  if blink_ok and type(blink.is_visible) == 'function' then
    return blink.is_visible()
  end

  local cmp_ok, cmp = pcall(require, 'cmp')
  if cmp_ok and type(cmp.visible) == 'function' then
    return cmp.visible()
  end

  if vim.fn.exists('*coc#pum#visible') == 1 then
    return vim.fn['coc#pum#visible']() == 1
  end

  -- native PUM fallback (mini.completion, vim built-in, etc.)
  return vim.fn.pumvisible() == 1
end

return M
