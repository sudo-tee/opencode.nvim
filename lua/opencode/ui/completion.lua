local M = {
  ---@type CompletionSource[]
  _sources = {},
  _last_line = '',
  _last_col = 0,
  _pending = {},
}

local completion_sources = {}

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

function M.on_insert_enter()
  M._last_line = vim.api.nvim_get_current_line()
  M._last_col = vim.api.nvim_win_get_cursor(0)[2]
end

function M.on_text_changed()
  if not next(M._pending) then
    return
  end

  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]

  -- detect inserted text
  local inserted = line:sub(M._last_col + 1, col)

  if M._pending[inserted] then
    local item = M._pending[inserted]

    M._pending = {}
    if item and item.data and item.data._opencode_item then
      M.on_completion_done(item.data._opencode_item)
    end
  end

  M._last_line = line
  M._last_col = col
end

function M.store_completion_items(items)
  M._pending = {}
  M._last_line = vim.api.nvim_get_current_line()
  M._last_col = vim.api.nvim_win_get_cursor(0)[2]

  for _, item in ipairs(items or {}) do
    local word = item.insertText
    if word then
      M._pending[word] = item
    end
  end
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

  -- Find the source that provided this item
  for _, source in ipairs(M._sources) do
    if source.name == item.source_name and source.on_complete then
      source.on_complete(item)
      break
    end
  end
end

function M.is_visible()
  return M._pending and next(M._pending) ~= nil
end

function M.has_completion_engine()
  local config = require('opencode.config')
  if config.preferred_completion_engine and config.preferred_completion_engine ~= 'vim_complete' then
    return true
  end

  local known_engines = {
    'cmp',
    'blink.cmp',
    'completion',
    'mini.completion',
    'minuet',
  }

  for _, engine in ipairs(known_engines) do
    if package.loaded[engine] then
      return true
    end
  end
  return false
end

return M
